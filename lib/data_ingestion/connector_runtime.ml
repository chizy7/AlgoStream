module Clock = Algostream_common_utils.Time_utils.Clock
module Event_bus = Algostream_infrastructure_event_bus.Event_bus
module Event_types = Algostream_infrastructure_event_bus.Event_types
module Exchange_config = Algostream_common_config.Exchange_config

let src = Logs.Src.create "algostream.data_ingestion.runtime"

module Log = (val Logs.src_log src : Logs.LOG)

let ms_to_s ms = float_of_int ms /. 1000.0

let publish_or_drop ~bus ~drop_counter ~supervisor event =
  if not (Event_bus.try_publish bus event) then (
    drop_counter := Int64.add !drop_counter 1L ;
    match event.Event_types.Event.priority with
    | Critical ->
      (* A dropped Critical event is the worst outcome the bus can produce — Data_gap lives in this
         band. Count it on the supervisor as well as logging, so it shows up in stats rather than
         only in the log. *)
      Connection_supervisor.note_critical_drop supervisor ;
      Log.err (fun m ->
        m "[%s] CRITICAL drop seq=%Ld" (Connection_supervisor.exchange supervisor) event.sequence_id)
    | _ -> ())


let publish_data_gap ~bus ~drop_counter ~supervisor ~symbol ~exchange ~expected ~received ~dropped =
  let payload =
    Event_types.Event.Data_gap
      {
        symbol;
        exchange;
        expected_seq = expected;
        received_seq = received;
        dropped_count = dropped;
      } in
  let event =
    Event_types.Event.create ~source:exchange ~priority:Event_types.Priority.Critical payload in
    publish_or_drop ~bus ~drop_counter ~supervisor event


let publish_risk_alert ~bus ~drop_counter ~supervisor ~code ~message ~severity =
  let payload = Event_types.Event.Risk_alert { code; message; severity } in
  let event =
    Event_types.Event.create
      ~source:(Connection_supervisor.exchange supervisor)
      ~priority:Event_types.Priority.High payload in
    publish_or_drop ~bus ~drop_counter ~supervisor event


(* Quality-gate a payload, possibly emit auxiliary events, return whether to publish the
   original. *)
let gate_payload ~bus ~drop_counter ~supervisor ~data_quality (payload : Event_types.Event.payload)
  : bool =
  let exchange = Connection_supervisor.exchange supervisor in
  let now = Clock.now_monotonic_ns () in
    match payload with
    | Market_tick { symbol; timestamp_ns; bid; ask; _ } ->
      (match
         Data_quality.check_market_tick data_quality ~symbol
           ~exchange_ts_ns:timestamp_ns
             (* Neither exchange numbers its quote updates, so there is nothing dense to check
                against; see Data_quality's note on what [sequence] must guarantee. *)
           ~ingest_ts_ns:now ~bid ~ask ~sequence:None
       with
      | Ok_publish -> true
      | Drop_stale { age_ns } ->
        publish_risk_alert ~bus ~drop_counter ~supervisor ~code:"STALE_TICK"
          ~message:(Printf.sprintf "stale tick %s age=%Ldms" symbol (Int64.div age_ns 1_000_000L))
          ~severity:1 ;
        false
      | Drop_crossed { bid; ask } ->
        publish_risk_alert ~bus ~drop_counter ~supervisor ~code:"CROSSED_BOOK"
          ~message:(Printf.sprintf "crossed book %s bid=%g ask=%g" symbol bid ask)
          ~severity:2 ;
        false
      | Out_of_order -> true (* market_tick has no trade_id ordering — won't fire *)
      | Gap_then_publish { expected; received; dropped } ->
        publish_data_gap ~bus ~drop_counter ~supervisor ~symbol ~exchange ~expected ~received
          ~dropped ;
        true)
    | Trade_print { symbol; timestamp_ns; sequence; _ } ->
      (match
         Data_quality.check_trade_print data_quality ~symbol ~exchange_ts_ns:timestamp_ns
           ~ingest_ts_ns:now ~sequence:(Some sequence)
       with
      | Ok_publish -> true
      | Out_of_order ->
        publish_risk_alert ~bus ~drop_counter ~supervisor ~code:"OUT_OF_ORDER_TRADE"
          ~message:(Printf.sprintf "out-of-order trade %s seq=%Ld" symbol sequence)
          ~severity:1 ;
        true
      | Gap_then_publish { expected; received; dropped } ->
        publish_data_gap ~bus ~drop_counter ~supervisor ~symbol ~exchange ~expected ~received
          ~dropped ;
        true
      | Drop_stale _ | Drop_crossed _ -> true)
    | _ -> true


let run_payload ~bus ~drop_counter ~supervisor ~data_quality (payload : Event_types.Event.payload) =
  if gate_payload ~bus ~drop_counter ~supervisor ~data_quality payload then
    let priority =
      match payload with
      | Event_types.Event.Risk_alert _ -> Event_types.Priority.High
      | Data_gap _ -> Event_types.Priority.Critical
      | _ -> Event_types.Priority.Normal in
    let event =
      Event_types.Event.create ~source:(Connection_supervisor.exchange supervisor) ~priority payload
    in
      publish_or_drop ~bus ~drop_counter ~supervisor event


(* Conduit resolves a URI by looking its scheme up as a *service*, via getservbyname and then
   Uri_services. Neither knows "ws" or "wss" — they are not in /etc/services — so every endpoint in
   Exchange_config resolved to `Unknown "unknown scheme"` and no connector ever established a
   connection. The supervisor dutifully reported the failure and retried forever, which is why the
   symptom was an endless reconnect loop rather than a crash.

   Registering the two WebSocket schemes with their well-known ports and TLS flag is the entire fix.
   An explicit port in the URI still wins — Binance's :9443 endpoint is unaffected — because the
   service port is only consulted when the URI omits one. *)
let websocket_service name =
  match name with
  | "ws" -> Lwt.return_some { Resolver.name = "ws"; port = 80; tls = false }
  | "wss" -> Lwt.return_some { Resolver.name = "wss"; port = 443; tls = true }
  | _ -> Lwt.return_none


(* Same shape as Resolver_lwt_unix.system, with the WebSocket schemes tried first. *)
let ws_resolver =
  Resolver_lwt.init
    ~service:Resolver_lwt.(websocket_service ++ Resolver_lwt_unix.system_service)
    ~rewrites:[ ("", Resolver_lwt_unix.system_resolver) ]
    ()


let connect_with_timeout ~connect_timeout_ms uri =
  let ctx = Lazy.force Conduit_lwt_unix.default_ctx in
  let resolver = ws_resolver in
  let work =
    Lwt.bind (Resolver_lwt.resolve_uri ~uri resolver) (fun endp ->
      Lwt.bind (Conduit_lwt_unix.endp_to_client ~ctx endp) (fun client ->
        Lwt.bind (Websocket_lwt_unix.connect ~ctx client uri) (fun conn -> Lwt.return_ok conn)))
  in
  let timeout =
    Lwt.bind (Lwt_unix.sleep (ms_to_s connect_timeout_ms)) (fun () -> Lwt.return_error `Timeout)
  in
    Lwt.catch (fun () -> Lwt.pick [ work; timeout ]) (fun exn -> Lwt.return_error (`Exn exn))


let send_subscribe (module E : Exchange.S) conn ~symbols =
  let msg = E.build_subscribe_message ~symbols in
  let frame = Websocket.Frame.create ~opcode:Text ~content:msg () in
    Websocket_lwt_unix.write conn frame


let handle_frame (module E : Exchange.S) ~bus ~drop_counter ~supervisor ~symbol_intern ~data_quality
  conn (frame : Websocket.Frame.t) =
  match frame.opcode with
  | Text ->
    Connection_supervisor.note_message supervisor ;
    let payloads = E.parse_frame ~symbol_intern frame.content in
      List.iter (run_payload ~bus ~drop_counter ~supervisor ~data_quality) payloads ;
      Lwt.return_ok ()
  | Binary ->
    Connection_supervisor.note_message supervisor ;
    Lwt.return_ok () (* not expected on these public feeds *)
  | Ping ->
    Connection_supervisor.note_message supervisor ;
    let pong = Websocket.Frame.create ~opcode:Pong ~content:frame.content () in
      Lwt.bind (Websocket_lwt_unix.write conn pong) (fun () -> Lwt.return_ok ())
  | Pong ->
    Connection_supervisor.note_message supervisor ;
    Lwt.return_ok ()
  | Close ->
    let close = Websocket.Frame.close 1000 in
      Lwt.bind
        (Lwt.catch (fun () -> Websocket_lwt_unix.write conn close) (fun _ -> Lwt.return_unit))
        (fun () ->
          Lwt.bind
            (Lwt.catch
               (fun () -> Websocket_lwt_unix.close_transport conn)
               (fun _ -> Lwt.return_unit))
            (fun () -> Lwt.return_error `Closed))
  | Continuation | Ctrl _ | Nonctrl _ -> Lwt.return_ok ()


let read_loop em ~bus ~drop_counter ~supervisor ~symbol_intern ~data_quality ~stop conn =
  let rec loop () =
    if Lwt.is_sleeping stop |> not then Lwt.return_unit
    else
      let read_promise = Websocket_lwt_unix.read conn in
        Lwt.bind
          (Lwt.pick [ Lwt.map (fun f -> `Frame f) read_promise; Lwt.map (fun () -> `Stop) stop ])
          (function
            | `Stop -> Lwt.return_unit
            | `Frame frame ->
              Lwt.bind
                (Lwt.catch
                   (fun () ->
                     handle_frame em ~bus ~drop_counter ~supervisor ~symbol_intern ~data_quality
                       conn frame)
                   (fun exn -> Lwt.return_error (`Exn exn)))
                (function Ok () -> loop () | Error _ -> Lwt.return_unit)) in
    loop ()


let pick_endpoint (config : Exchange_config.t) =
  match config.endpoints with
  | [] -> Error "no endpoints configured"
  | first :: _ -> Ok (Uri.of_string first)


let run em ~bus ~symbol_intern ~data_quality ~supervisor ~rate_limiter:_ ~drop_counter ~stop =
  let module E = (val em : Exchange.S) in
  let config = Connection_supervisor.config supervisor in
  let rec session_loop () =
    if not (Lwt.is_sleeping stop) then Lwt.return_unit
    else
      let delay_ns = Connection_supervisor.next_attempt_delay_ns supervisor in
      let delay_s =
        if Int64.compare delay_ns 0L > 0 then Int64.to_float delay_ns /. 1_000_000_000.0 else 0.0
      in
      let wait =
        if delay_s > 0.0 then Lwt.pick [ Lwt_unix.sleep delay_s; stop ] else Lwt.return_unit in
        Lwt.bind wait (fun () ->
          if not (Lwt.is_sleeping stop) then Lwt.return_unit
          else if not (Connection_supervisor.poll_ready_to_attempt supervisor) then session_loop ()
          else
            match pick_endpoint config with
            | Error reason ->
              Connection_supervisor.note_failure supervisor ~reason () ;
              session_loop ()
            | Ok uri ->
              Connection_supervisor.note_attempt supervisor ;
              Lwt.bind
                (connect_with_timeout ~connect_timeout_ms:config.retry.connect_timeout_ms uri)
                (function
                | Error err ->
                  let reason =
                    match err with
                    | `Timeout -> "connect timeout"
                    | `Exn exn -> Printf.sprintf "connect: %s" (Printexc.to_string exn) in
                    Connection_supervisor.note_failure supervisor ~reason () ;
                    session_loop ()
                | Ok conn ->
                  Connection_supervisor.note_connected supervisor ;
                  Log.info (fun m -> m "[%s] connected to %s" E.name (Uri.to_string uri)) ;
                  let prelude =
                    Lwt.catch
                      (fun () -> send_subscribe (module E) conn ~symbols:config.symbols)
                      (fun exn -> Lwt.fail exn) in
                    Lwt.bind
                      (Lwt.catch
                         (fun () -> Lwt.bind prelude (fun () -> Lwt.return_ok ()))
                         (fun exn -> Lwt.return_error (Printexc.to_string exn)))
                      (function
                        | Error reason ->
                          Connection_supervisor.note_failure supervisor
                            ~reason:("subscribe: " ^ reason) () ;
                          session_loop ()
                        | Ok () ->
                          Lwt.bind
                            (Lwt.catch
                               (fun () ->
                                 read_loop
                                   (module E)
                                   ~bus ~drop_counter ~supervisor ~symbol_intern ~data_quality ~stop
                                   conn)
                               (fun _ -> Lwt.return_unit))
                            (fun () ->
                              Lwt.bind
                                (Lwt.catch
                                   (fun () -> Websocket_lwt_unix.close_transport conn)
                                   (fun _ -> Lwt.return_unit))
                                (fun () ->
                                  if not (Lwt.is_sleeping stop) then Lwt.return_unit
                                  else (
                                    Connection_supervisor.note_failure supervisor
                                      ~reason:"connection closed" () ;
                                    session_loop ())))))) in
    session_loop ()
