(* algostream — the daemon.

   Wires the system together and serves the monitoring dashboard:

   event bus -> Lwt host -> ingestion (live feeds) or replay (recorded log) -> time-series /
   analytics / pairs processors -> telemetry collector -> runtime supervisor -> HTTP API + SSE push

   PAPER TRADING ONLY. Nothing here can place an order: the project has no venue credentials, no
   request signing and no trading endpoint. Every P&L figure the dashboard shows is simulated
   against live quotes.

   The API binds to the address in --http-host, defaulting to 127.0.0.1. Pass --auth-keys to require
   bearer credentials; without one it refuses to bind a non-loopback address. *)

module EB = Algostream_infrastructure_event_bus
module Event_bus = EB.Event_bus
module Event_log = EB.Event_log
module Lwt_host = Algostream_infrastructure_lwt_host.Lwt_host
module Ingestion = Algostream_data_ingestion.Ingestion_supervisor
module Data_quality = Algostream_data_ingestion.Data_quality
module Conn = Algostream_data_ingestion.Connection_supervisor
module Binance = Algostream_data_ingestion_binance
module Coinbase = Algostream_data_ingestion_coinbase
module Exchange_config = Algostream_common_config.Exchange_config
module An = Algostream_analytics.Processor
module Pp = Algostream_pairs.Processor
module Ts = Algostream_time_series.Processor
module Telemetry = Algostream_telemetry
module Runtime = Algostream_runtime
module Network = Algostream_infrastructure_network
module Reporting = Algostream_reporting
module Json = Network.Json
module Server = Network.Server
module PMR = Algostream_strategy.Pairs_mean_reversion
module Pair_id = Algostream_pairs.Pair_id
module Symbol = Algostream_normalization.Symbol
module Venue = Algostream_order_management.Venue
module Auth = Algostream_infrastructure_auth
module Scope = Auth.Scope
module Audit_log = Algostream_infrastructure_persistence.Audit_log

type cli = {
  mutable exchange : string;
  mutable symbols : string;
  mutable replay : string option;
  mutable speed : float;
  mutable y_symbol : string;
  mutable x_symbol : string;
  mutable capital : float;
  mutable http_host : string;
  mutable http_port : int;
  mutable static_root : string option;
  mutable duration_s : int;
  mutable no_strategy : bool;
  mutable variant : (string * float) list;
  mutable gc_tune : bool;
  mutable pin_cores : int list;
  mutable auth_keys : string option;
  mutable audit_dir : string option;
  mutable insecure_plaintext_bind : bool;
}

let default_cli () =
  {
    exchange = "both";
    symbols = "BTCUSDT,ETHUSDT";
    replay = None;
    speed = 1.0;
    y_symbol = "BTCUSDT";
    x_symbol = "ETHUSDT";
    capital = 100_000.0;
    http_host = "127.0.0.1";
    http_port = 8080;
    static_root = None;
    duration_s = 0;
    no_strategy = false;
    variant = [];
    gc_tune = false;
    pin_cores = [];
    auth_keys = None;
    audit_dir = None;
    insecure_plaintext_bind = false;
  }


let usage () =
  print_string
    {|algostream: live daemon with simulated execution and a monitoring dashboard

  Market data (pick one):
    --exchange {binance|coinbase|both}  live public feeds       (default both)
    --symbols  A,B                      symbols to subscribe    (default BTCUSDT,ETHUSDT)
    --replay   PATH                     replay a recorded log instead of connecting
    --speed    F                        replay speed multiplier (default 1.0)

  Strategy (paper):
    --y SYM --x SYM                     pair legs               (default BTCUSDT / ETHUSDT)
    --capital N                         starting capital        (default 100000)
    --no-strategy                       monitor only
    --variant  K=V[,K=V]                run a second instance "pairs-2" on the same market
                                        with these parameter overrides, for /api/compare

  Dashboard:
    --http-port N                       (default 8080)
    --http-host H                       (default 127.0.0.1 — see below)
    --static DIR                        serve a dashboard build from DIR
    --duration N                        exit after N seconds    (default 0 = run forever)

  Security:
    --auth-keys PATH                    keystore; without it the API is unauthenticated
                                        and may only bind loopback
    --audit-dir DIR                     hash-chained audit log of every control action
    --insecure-plaintext-bind           allow a non-loopback bind without TLS in front

  Tuning (all off by default — see docs/guides/performance_tuning.md):
    --gc-tune                           16 MiB minor heap, space_overhead 80
    --pin-cores A,B,...                 pin Domains to these cores, in spawn order
                                        (Linux only; a no-op with a warning elsewhere)

Every order is simulated; this project has no venue connectivity. Binding --http-host to anything
but loopback requires --auth-keys, and refuses to start without it.
|} ;
  exit 0


let parse_args () =
  let c = default_cli () in
  (* Accept --flag=value as well as --flag value; see Cli.expand_equals for why this exists. *)
  let argv = Algostream_common_utils.Cli.expand_equals Sys.argv in
  let n = Array.length argv in
  let need i what =
    if i + 1 >= n then (
      Printf.eprintf "algostream: --%s needs a value\n" what ;
      exit 2)
    else argv.(i + 1) in
  let i = ref 1 in
    while !i < n do
      (match argv.(!i) with
      | "--exchange" ->
        c.exchange <- need !i "exchange" ;
        incr i
      | "--symbols" ->
        c.symbols <- need !i "symbols" ;
        incr i
      | "--replay" ->
        c.replay <- Some (need !i "replay") ;
        incr i
      | "--speed" ->
        c.speed <- float_of_string (need !i "speed") ;
        incr i
      | "--y" ->
        c.y_symbol <- need !i "y" ;
        incr i
      | "--x" ->
        c.x_symbol <- need !i "x" ;
        incr i
      | "--capital" ->
        c.capital <- float_of_string (need !i "capital") ;
        incr i
      | "--http-port" ->
        c.http_port <- int_of_string (need !i "http-port") ;
        incr i
      | "--http-host" ->
        c.http_host <- need !i "http-host" ;
        incr i
      | "--static" ->
        c.static_root <- Some (need !i "static") ;
        incr i
      | "--duration" ->
        c.duration_s <- int_of_string (need !i "duration") ;
        incr i
      | "--auth-keys" ->
        c.auth_keys <- Some (need !i "auth-keys") ;
        incr i
      | "--audit-dir" ->
        c.audit_dir <- Some (need !i "audit-dir") ;
        incr i
      | "--insecure-plaintext-bind" -> c.insecure_plaintext_bind <- true
      | "--gc-tune" -> c.gc_tune <- true
      | "--pin-cores" ->
        c.pin_cores <-
          need !i "pin-cores" |> String.split_on_char ',' |> List.map String.trim
          |> List.filter (fun s -> s <> "")
          |> List.map int_of_string ;
        incr i
      | "--no-strategy" -> c.no_strategy <- true
      | "--variant" ->
        (* KEY=VALUE[,KEY=VALUE]. Repeatable, so a long list need not be one shell token. *)
        let spec = need !i "variant" in
        let one kv =
          match String.index_opt kv '=' with
          | None ->
            Printf.eprintf "algostream: --variant expects KEY=VALUE, got %S\n" kv ;
            exit 2
          | Some k ->
            let name = String.sub kv 0 k in
            let v = String.sub kv (k + 1) (String.length kv - k - 1) in
              (match float_of_string_opt v with
              | Some f -> (name, f)
              | None ->
                Printf.eprintf "algostream: --variant %S: %S is not a number\n" name v ;
                exit 2) in
        let parts = String.split_on_char ',' spec |> List.filter (fun s -> s <> "") in
          c.variant <- c.variant @ List.map one parts ;
          incr i
      | "-h" | "--help" -> usage ()
      | other ->
        Printf.eprintf "algostream: unknown argument %s (try --help)\n" other ;
        exit 2) ;
      incr i
    done ;
    c


let split_commas s =
  String.split_on_char ',' s |> List.map String.trim |> List.filter (fun x -> x <> "")


let parse_symbol raw =
  match Symbol.parse ~exchange:"binance" ~raw with
  | Some s -> s
  | None ->
    (* An unrecognised ticker still runs, under a synthetic canonical symbol. *)
    { Symbol.base = raw; quote = "USD"; asset_class = Symbol.Crypto }


let ingestion_entries c =
  let syms = split_commas c.symbols in
  let binance = Exchange_config.binance_default ~symbols:syms in
  let coinbase = Exchange_config.coinbase_default ~symbols:syms in
    match String.lowercase_ascii c.exchange with
    | "binance" -> [ Ingestion.{ em = (module Binance.Connector); config = binance } ]
    | "coinbase" -> [ Ingestion.{ em = (module Coinbase.Connector); config = coinbase } ]
    | _ ->
      [
        Ingestion.{ em = (module Binance.Connector); config = binance };
        Ingestion.{ em = (module Coinbase.Connector); config = coinbase };
      ]


(* ───────────────────────── API routes ───────────────────────── *)

let routes ~telemetry ~runtime ~auth_required =
  let ok j = (j, 200) in
  let snap_runtime () = Runtime.Supervisor.snapshot runtime in
  let control name f : Server.handler =
   fun req ->
    match List.assoc_opt "id" req.Server.path_params with
    | None -> (Json.error "missing strategy id", 400)
    | Some id ->
      if f ~strategy_id:id then
        ok
          (Json.obj
             [ ("ok", Json.bool true); ("action", Json.string name); ("id", Json.string id) ])
      else (Json.error (Printf.sprintf "no strategy %S" id), 404) in
    [
      {
        Server.meth = `GET;
        path = "/api/health";
        scope = Scope.Public;
        handler =
          (fun _ ->
            let t = Telemetry.Collector.snapshot telemetry in
            let code =
              match t.Telemetry.Snapshot.overall with Telemetry.Health.Failed _ -> 503 | _ -> 200
            in
              ( Json.obj
                  [
                    ("status", Json.of_health_status t.Telemetry.Snapshot.overall);
                    ("uptime_ns", Json.int64 t.Telemetry.Snapshot.uptime_ns);
                    ("mode", Json.string "paper");
                    (* The dashboard probes this endpoint to tell a live daemon from the recorded
                       demo, so it has to stay public. This field is how the page knows to ask for a
                       key rather than guess from a 401 it would read as "not a daemon". *)
                    ("auth_required", Json.bool auth_required);
                  ],
                code ));
      };
      {
        (* Liveness, which is a different question from health, and conflating the two is a
           production outage waiting to happen.

           /api/health aggregates every subsystem, so an unreachable exchange takes it to 503 and
           holds it there once the circuit breaker opens. Kubernetes' livenessProbe was pointed at
           it: three failures at a 30 s period means the pod is killed ~90 s after a feed goes away,
           restarted, fails identically, and CrashLoops — on an external dependency that no restart
           can fix. Measured here with Binance geo-blocked: 200 (degraded) at 15 s, 503 (failed)
           from 45 s onwards, permanently.

           Liveness must answer only "is this process wedged?". If the HTTP server can run this
           handler, the answer is no. Readiness and startup stay on /api/health, where a degraded
           feed *should* take the pod out of service. *)
        Server.meth = `GET;
        path = "/api/live";
        scope = Scope.Public;
        handler =
          (fun _ ->
            ( Json.obj
                [
                  ("status", Json.string "alive");
                  ("mode", Json.string "paper");
                  (* Named so nobody wires a readiness or alerting check to it by mistake. *)
                  ("note", Json.string "process liveness only; see /api/health for subsystem state");
                ],
              200 ));
      };
      {
        Server.meth = `GET;
        path = "/api/whoami";
        scope = Scope.Read;
        (* Ordinary route rather than a dispatcher special case, which is the argument for putting
           the principal on [request] at all: the dashboard greys out pause/stop for a read-only
           key, and needs to be told which it holds. Returns no secret — a principal never carries
           one. *)
        handler =
          (fun req ->
            ok
              (Json.obj
                 (List.map
                    (fun (k, v) -> (k, Json.string v))
                    (Auth.Principal.to_assoc req.Server.principal))));
      };
      {
        Server.meth = `GET;
        path = "/api/telemetry";
        scope = Scope.Read;
        handler = (fun _ -> ok (Json.of_telemetry (Telemetry.Collector.snapshot telemetry)));
      };
      {
        Server.meth = `GET;
        path = "/api/strategies";
        scope = Scope.Read;
        handler = (fun _ -> ok (Json.of_runtime (snap_runtime ())));
      };
      {
        Server.meth = `GET;
        path = "/api/strategies/:id";
        scope = Scope.Read;
        handler =
          (fun req ->
            let id = Option.value ~default:"" (List.assoc_opt "id" req.Server.path_params) in
              match
                List.find_opt
                  (fun (i : Runtime.Snapshot.instance) ->
                    String.equal i.Runtime.Snapshot.strategy_id id)
                  (snap_runtime ()).Runtime.Snapshot.instances
              with
              | Some i -> ok (Json.of_runtime_instance i)
              | None -> (Json.error (Printf.sprintf "no strategy %S" id), 404));
      };
      {
        (* Deliberately its own endpoint rather than a field on the SSE frame. The frame goes out at
           4 Hz to every connected client; two 2048-point NAV curves would be tens of kilobytes per
           second per client, for data the rings only refresh once a second. The dashboard polls
           this on its own slower timer. *)
        Server.meth = `GET;
        path = "/api/compare";
        scope = Scope.Read;
        handler =
          (fun req ->
            let q k = List.assoc_opt k req.Server.query in
              match (q "a", q "b") with
              | Some a_id, Some b_id ->
                (match Reporting.Live_compare.of_supervisor runtime ~a_id ~b_id with
                | Ok c -> ok (Reporting.Live_compare.to_json c)
                | Error (`Unknown_instance _ as e) ->
                  (Json.error (Reporting.Live_compare.error_to_string e), 404)
                | Error e ->
                  (* Not-yet-comparable is a 409, not a 404 or a 500: both instances exist, the
                     request is well formed, and it will succeed once they have run long enough. *)
                  (Json.error (Reporting.Live_compare.error_to_string e), 409))
              | _ -> (Json.error "both ?a= and ?b= strategy ids are required", 400));
      };
      {
        Server.meth = `POST;
        path = "/api/strategies/:id/pause";
        scope = Scope.Control;
        handler = control "pause" (Runtime.Supervisor.pause runtime);
      };
      {
        Server.meth = `POST;
        path = "/api/strategies/:id/resume";
        scope = Scope.Control;
        handler = control "resume" (Runtime.Supervisor.resume runtime);
      };
      {
        Server.meth = `POST;
        path = "/api/strategies/:id/stop";
        scope = Scope.Control;
        handler = control "stop" (Runtime.Supervisor.stop_instance runtime);
      };
      {
        Server.meth = `PUT;
        path = "/api/strategies/:id/allocation";
        scope = Scope.Control;
        handler =
          (fun req ->
            match List.assoc_opt "id" req.Server.path_params with
            | None -> (Json.error "missing strategy id", 400)
            | Some id ->
              (match float_of_string_opt (String.trim req.Server.body) with
              | None -> (Json.error "body must be a number", 400)
              | Some v ->
                if Runtime.Supervisor.set_allocation runtime ~strategy_id:id v then
                  ok (Json.obj [ ("ok", Json.bool true); ("allocation", Json.float v) ])
                else (Json.error (Printf.sprintf "no strategy %S" id), 404)));
      };
      {
        Server.meth = `GET;
        path = "/api/reports";
        scope = Scope.Read;
        handler =
          (fun _ -> ok (Json.obj [ ("reports", Json.list Json.string Reporting.Report.names) ]));
      };
      {
        Server.meth = `GET;
        path = "/api/reports/:name";
        scope = Scope.Read;
        handler =
          (fun req ->
            let name = Option.value ~default:"" (List.assoc_opt "name" req.Server.path_params) in
            let fmt_s = Option.value ~default:"json" (List.assoc_opt "format" req.Server.query) in
              match Reporting.Export.format_of_string fmt_s with
              | Error e -> (Json.error e, 400)
              | Ok fmt ->
                (match
                   Reporting.Report.by_name name ~runtime:(snap_runtime ()) ~risk_snapshot:None
                 with
                | Error e -> (Json.error e, 404)
                | Ok table ->
                  ok
                    (Json.obj
                       [
                         ("report", Json.string table.Reporting.Report.title);
                         ("format", Json.string (Reporting.Export.format_to_string fmt));
                         ("body", Json.string (Reporting.Report.render table fmt));
                       ])));
      };
    ]


(* ───────────────────────── main ───────────────────────── *)

let () =
  let c = parse_args () in
    Logs.set_reporter (Logs.format_reporter ()) ;
    Logs.set_level (Some Logs.Info) ;
    Printf.printf "algostream: simulated execution, no venue connectivity\n%!" ;

    (* Both tuning knobs must be applied before anything is spawned: [Gc.set] so the Domains inherit
       the minor-heap size, and [set_plan] so each Domain can claim a core as it starts. *)
    if c.gc_tune then (
      Algostream_common_utils.Benchmark.MemoryOptimization.optimize_gc_for_latency () ;
      let g = Gc.get () in
        Logs.info (fun m ->
          m "gc tuned: minor heap %d MiB, space_overhead %d"
            (g.minor_heap_size * (Sys.word_size / 8) / 1024 / 1024)
            g.space_overhead)) ;
    (match c.pin_cores with
    | [] -> ()
    | cores ->
      if not Algostream_common_utils.Affinity.available then
        Logs.warn (fun m ->
          m
            "--pin-cores was given but this platform has no cpu affinity API (Linux only); \
             continuing unpinned")
      else Algostream_common_utils.Affinity.set_plan cores) ;

    let bus = Event_bus.create ~capacity_per_band:65_536 () in
      Event_bus.start bus ;

      let ts_proc = Ts.start ~bus ~intervals_ns:[ 60_000_000_000L ] () in
      let an_proc = An.start ~bus () in
      let pair = Pair_id.of_symbols (parse_symbol c.y_symbol) (parse_symbol c.x_symbol) in
      let pp_proc =
        Pp.start ~bus ~pairs:[ { Pp.pair; y_raw = c.y_symbol; x_raw = c.x_symbol } ] () in

      let telemetry = Telemetry.Collector.create ~bus () in
        Telemetry.Collector.start telemetry ;
        (* A replayed log makes the latency SLA fire on every event — the measurement is the age of
           the log, not a delivery time. Keep sampling, stop alerting. *)
        (match c.replay with
        | Some _ -> Telemetry.Collector.set_latency_alerting telemetry false
        | None -> ()) ;

        let runtime = Runtime.Supervisor.create ~bus () in
          if not c.no_strategy then (
            let register ~id ~params =
              let cfg =
                {
                  (Runtime.Instance.default_config ~strategy_id:id ~venue:Venue.binance_spot
                     ~initial_capital:c.capital)
                  with
                  Runtime.Instance.symbols = [ c.y_symbol; c.x_symbol ];
                } in
              let inst = Runtime.Instance.create (module PMR) ~params ~config:cfg in
                if not (Runtime.Supervisor.add runtime inst) then (
                  Printf.eprintf "algostream: duplicate strategy id %S\n" id ;
                  exit 2) in
              register ~id:"pairs-1" ~params:PMR.default_params ;
              Printf.printf "  strategy pairs-1: %s / %s, capital %.0f (simulated)\n%!" c.y_symbol
                c.x_symbol c.capital ;
              (* A second instance on the same market with different parameters. Both see the same
                 records from the same supervisor, so /api/compare is measuring the parameters and
                 nothing else — which is the only way the comparison means anything. *)
              match c.variant with
              | [] -> ()
              | overrides ->
                let base = PMR.params_to_assoc PMR.default_params in
                let merged =
                  List.map
                    (fun (k, v) ->
                      match List.assoc_opt k overrides with Some v' -> (k, v') | None -> (k, v))
                    base in
                  List.iter
                    (fun (k, _) ->
                      if not (List.mem_assoc k base) then (
                        Printf.eprintf "algostream: --variant: %S is not a parameter of %s\n" k
                          PMR.name ;
                        Printf.eprintf "  known: %s\n" (String.concat ", " (List.map fst base)) ;
                        exit 2))
                    overrides ;
                  (match PMR.params_of_assoc merged with
                  | Error e ->
                    Printf.eprintf "algostream: --variant produced invalid parameters: %s\n" e ;
                    exit 2
                  | Ok params ->
                    register ~id:"pairs-2" ~params ;
                    Printf.printf "  strategy pairs-2: same market, %s\n%!"
                      (String.concat " "
                         (List.map (fun (k, v) -> Printf.sprintf "%s=%g" k v) overrides))) ;
                  Printf.printf
                    "  compare them at /api/compare?a=pairs-1&b=pairs-2 once both have sampled\n%!") ;

          (* Subsystems register as closures, so no library depends on another to be observable.

             [health] is what makes /api/health able to fail. Without it the endpoint folds an empty
             list, which Health.worst reports as Ok unconditionally — and Kubernetes liveness,
             readiness and startup probes all point at it. *)
          let reg ?health name metrics =
            Telemetry.Collector.register telemetry { Telemetry.Collector.name; metrics; health }
          in

          (* A drain loop that is dropping is behind; that is degradation, not failure — the
             processor is still publishing, just from a thinned stream. *)
          (* Health.threshold compares with >=, so the degraded bound is 1.0, not 0.0: a single
             dropped event is degradation, zero is healthy. *)
          let drop_health what value =
            Telemetry.Health.threshold ~what ~value ~degraded_above:1.0 ~failed_above:10_000.0
              ~unit_:"dropped" in
            reg "runtime"
              ~health:(fun () ->
                let s = Runtime.Supervisor.snapshot runtime in
                  drop_health "runtime queue" (float_of_int s.Runtime.Snapshot.n_dropped_full_queue))
              (Runtime.Supervisor.telemetry_metrics runtime) ;
            reg "analytics"
              ~health:(fun () ->
                drop_health "analytics queue"
                  (Int64.to_float (An.stats an_proc).An.ticks_dropped_full_queue))
              (fun () ->
                let s = An.stats an_proc in
                  [
                    ("observed", Int64.to_float s.An.ticks_observed);
                    ("processed", Int64.to_float s.An.ticks_processed);
                    ("dropped_full_queue", Int64.to_float s.An.ticks_dropped_full_queue);
                    ("active_symbols", float_of_int s.An.active_symbols);
                  ]) ;
            reg "pairs"
              ~health:(fun () ->
                drop_health "pairs queue"
                  (Int64.to_float (Pp.stats pp_proc).Pp.ticks_dropped_full_queue))
              (fun () ->
                let s = Pp.stats pp_proc in
                  [
                    ("observed", Int64.to_float s.Pp.ticks_observed);
                    ("processed", Int64.to_float s.Pp.ticks_processed);
                    ("bars", Int64.to_float s.Pp.bars_processed);
                    ("active_pairs", float_of_int s.Pp.active_pairs);
                  ]) ;
            reg "time_series" (fun () ->
              let s = Ts.stats ts_proc in
                [
                  ("observed", Int64.to_float s.Ts.ticks_observed);
                  ("bars_emitted", Int64.to_float s.Ts.bars_emitted);
                  ("active_keys", float_of_int s.Ts.active_keys);
                ]) ;

            (* One Lwt scheduler: ingestion fibers and the HTTP server both attach to it. *)
            let host = Lwt_host.create () in
            let ingestion =
              match c.replay with
              | Some _ -> None
              | None ->
                Printf.printf "  ingesting %s from %s\n%!" c.symbols c.exchange ;
                Some (Ingestion.attach ~host ~bus ~entries:(ingestion_entries c) ()) in

            (match ingestion with
            | None -> ()
            | Some ing ->
              Telemetry.Collector.register telemetry
                {
                  Telemetry.Collector.name = "ingestion";
                  metrics =
                    (fun () ->
                      List.concat_map
                        (fun (s : Ingestion.per_exchange_stats) ->
                          let p k = Printf.sprintf "%s.%s" s.Ingestion.exchange k in
                          let dq = s.Ingestion.data_quality in
                            [
                              (p "bus_drops", Int64.to_float s.Ingestion.bus_drops);
                              (p "critical_drops", Int64.to_float s.Ingestion.critical_drops);
                              (p "sequence_gaps", float_of_int dq.Data_quality.sequence_gaps);
                              (p "stale_ticks", float_of_int dq.Data_quality.stale_ticks);
                              (p "crossed_books", float_of_int dq.Data_quality.crossed_books);
                            ])
                        (Ingestion.live_stats ing));
                  (* The case that motivated this: a feed that never connects drops nothing and
                     produces nothing, so every counter above reads zero and looks healthy. Only the
                     connection mirror can tell a quiet feed from a dead one. *)
                  health =
                    Some
                      (fun () ->
                        let per_feed =
                          List.map
                            (fun (s : Ingestion.per_exchange_stats) ->
                              let name = s.Ingestion.exchange in
                                if Int64.compare s.Ingestion.critical_drops 0L > 0 then
                                  Telemetry.Health.Failed
                                    (Printf.sprintf "%s dropped %Ld critical events" name
                                       s.Ingestion.critical_drops)
                                else
                                  match s.Ingestion.connection with
                                  | None -> Telemetry.Health.Degraded (name ^ " has not started yet")
                                  | Some m ->
                                    (match m.Conn.state with
                                    | Conn.Open_circuit _ ->
                                      Telemetry.Health.Failed (name ^ " circuit breaker is open")
                                    | Conn.Reconnecting { attempt; _ } ->
                                      Telemetry.Health.Degraded
                                        (Printf.sprintf "%s reconnecting (attempt %d)" name attempt)
                                    | Conn.Connecting ->
                                      Telemetry.Health.Degraded (name ^ " connecting")
                                    | Conn.Connected ->
                                      (* Connected but silent is the interesting failure — the
                                         socket is up and no data is arriving. *)
                                      Telemetry.Health.stale ~what:(name ^ " feed")
                                        ~age_ns:m.Conn.time_since_last_message_ns
                                        ~degraded_after_ns:30_000_000_000L
                                        ~failed_after_ns:120_000_000_000L))
                            (Ingestion.live_stats ing) in
                          Telemetry.Health.worst per_feed);
                }) ;

            (* Latency is [now - event.timestamp_ns], which is only a delivery time when the source
               is live. Replayed events carry their recorded timestamps, so the histogram measures
               the age of the log and every event trips the SLA. Publish the source so the dashboard
               can say so instead of showing a red 100%. *)
            let source = match c.replay with Some _ -> "replay" | None -> "live" in
            let snapshot_json () =
              Json.obj
                [
                  ("source", Json.string source);
                  ("telemetry", Json.of_telemetry (Telemetry.Collector.snapshot telemetry));
                  ("runtime", Json.of_runtime (Runtime.Supervisor.snapshot runtime));
                ] in
            let keystore =
              match c.auth_keys with
              | None -> None
              | Some path ->
                (match Auth.Keystore.load path with
                | Ok ks ->
                  Printf.printf "  auth      %d key(s) from %s\n%!"
                    (List.length (Auth.Keystore.records ks))
                    path ;
                  Some ks
                | Error e ->
                  Printf.eprintf "algostream: %s\n" e ;
                  exit 2) in
            let audit_writer =
              match c.audit_dir with
              | None -> None
              | Some dir ->
                (match Audit_log.Writer.open_ dir with
                | Ok w ->
                  Printf.printf "  audit     %s (seq %Ld, head %s)\n%!" (Audit_log.Writer.path w)
                    (Audit_log.Writer.last_seq w)
                    (String.sub (Audit_log.Writer.head_hash w) 0 16) ;
                  Some w
                | Error e ->
                  Printf.eprintf "algostream: %s\n" e ;
                  exit 2) in
            let server_config =
              {
                Server.host = c.http_host;
                port = c.http_port;
                static_root = c.static_root;
                push_interval_s = 0.25;
              } in
              (* Refuse before listening, not after. *)
              (match
                 Server.check_bind ~config:server_config ~auth:keystore
                   ~allow_insecure:c.insecure_plaintext_bind
               with
              | Ok () -> ()
              | Error e ->
                Printf.eprintf "algostream: %s\n" e ;
                exit 2) ;
              let server =
                Server.create ~config:server_config ~auth:keystore
                  ~audit:
                    (Option.map
                       (fun w rec_ ->
                         match Audit_log.Writer.append w rec_ with
                         | Ok () -> ()
                         | Error e -> Logs.err (fun m -> m "audit append failed: %s" e))
                       audit_writer)
                  ~metrics:
                    (Some
                       (fun () ->
                         ( Telemetry.Prometheus.content_type,
                           Telemetry.Prometheus.render (Telemetry.Collector.snapshot telemetry) )))
                  ~routes:(routes ~telemetry ~runtime ~auth_required:(c.auth_keys <> None))
                  ~snapshot:snapshot_json in
                Server.attach server host ;
                Lwt_host.start host ;
                (* Every Domain has now been spawned and claimed its core, so this is the first
                   point at which the pinning picture is complete. Reported once, here, rather than
                   logged from six places scattered through the boot sequence. *)
                (match Algostream_common_utils.Affinity.report () with
                | [] -> ()
                | entries ->
                  List.iter
                    (fun (name, result) ->
                      match result with
                      | Ok core -> Printf.printf "  pinned %-18s -> core %d\n%!" name core
                      | Error e ->
                        Printf.printf "  pinned %-18s -> FAILED: %s\n%!" name
                          (Algostream_common_utils.Affinity.error_to_string e))
                    entries ;
                  let unpinned = List.length entries in
                    if unpinned < List.length c.pin_cores then
                      Printf.printf "  note: %d cores given, %d Domains claimed\n%!"
                        (List.length c.pin_cores) unpinned) ;
                (* --static points at site/, whose index is the landing page; the dashboard lives
                   one level down. Print where it actually is rather than where the root is. *)
                (match c.static_root with
                | Some _ ->
                  (* Report what this run actually is. The literal "(unauthenticated, loopback)"
                     printed here regardless of --auth-keys, so an authenticated daemon announced
                     itself as an open one. *)
                  Printf.printf "  dashboard http://%s:%d/dashboard/  (%s)\n%!" c.http_host
                    c.http_port
                    (if c.auth_keys = None then "unauthenticated" else "authenticated")
                | None ->
                  Printf.printf "  api       http://%s:%d/api/  (no --static given, so no UI)\n%!"
                    c.http_host c.http_port) ;

                (match c.replay with
                | None -> ()
                | Some path ->
                  Printf.printf "  replaying %s at %.2fx\n%!" path c.speed ;
                  Printf.printf
                    "  note: replayed events carry their recorded timestamps, so end-to-end\n\
                    \        latency measures the age of the log, not bus latency\n\
                     %!" ;
                  let n = Event_log.replay bus ~path ~speed:c.speed () in
                    Printf.printf "  replayed %d events\n%!" n) ;

                let stop_now = ref false in
                  Sys.set_signal Sys.sigint (Sys.Signal_handle (fun _ -> stop_now := true)) ;
                  (try Sys.set_signal Sys.sigterm (Sys.Signal_handle (fun _ -> stop_now := true))
                   with _ -> ()) ;
                  let deadline =
                    if c.duration_s = 0 then infinity
                    else Unix.gettimeofday () +. float_of_int c.duration_s in
                    while (not !stop_now) && Unix.gettimeofday () < deadline do
                      Unix.sleepf 0.25
                    done ;

                    print_string "\nshutting down\n" ;
                    Runtime.Supervisor.stop runtime ;
                    (match ingestion with Some ing -> ignore (Ingestion.stop ing) | None -> ()) ;
                    Lwt_host.stop host ;
                    Telemetry.Collector.stop telemetry ;
                    Pp.stop pp_proc ;
                    An.stop an_proc ;
                    Ts.stop ts_proc ;
                    Event_bus.stop bus ;
                    print_string
                      (Telemetry.Snapshot.to_string (Telemetry.Collector.snapshot telemetry)) ;
                    print_string (Runtime.Snapshot.to_string (Runtime.Supervisor.snapshot runtime))
