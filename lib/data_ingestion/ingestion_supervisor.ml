module Event_bus = Algostream_infrastructure_event_bus.Event_bus
module Event_types = Algostream_infrastructure_event_bus.Event_types
module Exchange_config = Algostream_common_config.Exchange_config
module Lwt_host = Algostream_infrastructure_lwt_host.Lwt_host

let src = Logs.Src.create "algostream.data_ingestion.supervisor"

module Log = (val Logs.src_log src : Logs.LOG)

type entry = {
  em : (module Exchange.S);
  config : Exchange_config.t;
}

type per_exchange_stats = {
  exchange : string;
  data_quality : Data_quality.stats;
  bus_drops : int64;
  critical_drops : int64;
  connection : Connection_supervisor.mirror option;
}

type t = {
  stop_flag : bool Atomic.t;
  joined : bool Atomic.t;
  owned_host : Lwt_host.t option;
    (** [Some] when we created the host ourselves and must stop it; [None] when we are one tenant of
        a host the caller owns. *)
  live : per_exchange_stats list Atomic.t;
}

(** How often the counters kept on the ingestion Domain are republished as an immutable snapshot.
    Fast enough for a dashboard, slow enough to be free. *)
let stats_interval_s = 0.25

(* Everything below [build] runs on the host Domain. The tables are created here, on the caller's
   Domain, but are only ever touched by the host afterwards — [Domain.spawn] gives the necessary
   happens-before. Cross-Domain readers never see the tables; they read [live], which is an
   immutable list published with [Atomic.set]. *)
let build ~bus ~entries ~live =
  let symbol_intern = Symbol_intern.create () in
  let dq_table = Hashtbl.create (List.length entries) in
  let drops_table = Hashtbl.create (List.length entries) in
  let critical_drops_table = Hashtbl.create (List.length entries) in
  (* Connection supervisors are created inside each connector fiber but their mirrors have to be
     readable by the stats publisher, so they are registered here as they come up. Both run on the
     Lwt host Domain, the same happens-before the other tables rely on. *)
  let supervisor_table = Hashtbl.create (List.length entries) in
    List.iter
      (fun e ->
        Hashtbl.replace dq_table e.config.name (Data_quality.create ~exchange:e.config.name ()) ;
        Hashtbl.replace drops_table e.config.name (ref 0L) ;
        Hashtbl.replace critical_drops_table e.config.name (ref 0L))
      entries ;

    let snapshot_now () =
      List.map
        (fun e ->
          {
            exchange = e.config.name;
            data_quality = Data_quality.stats (Hashtbl.find dq_table e.config.name);
            bus_drops = !(Hashtbl.find drops_table e.config.name);
            critical_drops = !(Hashtbl.find critical_drops_table e.config.name);
            connection =
              Hashtbl.find_opt supervisor_table e.config.name
              |> Option.map Connection_supervisor.mirror;
          })
        entries in

    Atomic.set live (snapshot_now ()) ;

    let heartbeat ~stop =
      let rec loop () =
        if not (Lwt.is_sleeping stop) then Lwt.return_unit
        else
          Lwt.bind
            (Lwt.pick [ Lwt_unix.sleep 1.0; stop ])
            (fun () ->
              if not (Lwt.is_sleeping stop) then Lwt.return_unit
              else
                let event =
                  Event_types.Event.create ~source:"ingestion" ~priority:Event_types.Priority.Low
                    Event_types.Event.Heartbeat in
                  ignore (Event_bus.try_publish bus event : bool) ;
                  loop ()) in
        loop () in

    let stats_publisher ~stop =
      let rec loop () =
        if not (Lwt.is_sleeping stop) then Lwt.return_unit
        else
          Lwt.bind
            (Lwt.pick [ Lwt_unix.sleep stats_interval_s; stop ])
            (fun () ->
              Atomic.set live (snapshot_now ()) ;
              if not (Lwt.is_sleeping stop) then Lwt.return_unit else loop ()) in
        loop () in

    (* All connectors plus the finalizer live in one fiber so the last snapshot is taken after every
       connector has written its final [critical_drops]. *)
    let connectors ~stop =
      let one e =
        let dq = Hashtbl.find dq_table e.config.name in
        let drops = Hashtbl.find drops_table e.config.name in
        let supervisor = Connection_supervisor.create ~config:e.config ~bus () in
          Hashtbl.replace supervisor_table e.config.name supervisor ;
          let rate_limiter =
            Rate_limiter.create ~capacity:e.config.rate_limit_per_sec
              ~refill_per_sec:e.config.rate_limit_per_sec ~reserved:e.config.pong_reserve_per_sec ()
          in
            Lwt.bind
              (Lwt.catch
                 (fun () ->
                   Connector_runtime.run e.em ~bus ~symbol_intern ~data_quality:dq ~supervisor
                     ~rate_limiter ~drop_counter:drops ~stop)
                 (fun exn ->
                   Log.err (fun m ->
                     m "[%s] connector exited with %s" e.config.name (Printexc.to_string exn)) ;
                   Lwt.return_unit))
              (fun () ->
                Hashtbl.find critical_drops_table e.config.name
                := Connection_supervisor.critical_drops supervisor ;
                Lwt.return_unit) in
        Lwt.bind
          (Lwt.join (List.map one entries))
          (fun () ->
            Atomic.set live (snapshot_now ()) ;
            Lwt.return_unit) in

    [
      ("ingestion.heartbeat", heartbeat);
      ("ingestion.stats", stats_publisher);
      ("ingestion.connectors", connectors);
    ]


let attach ~host ~bus ~entries () =
  let stop_flag = Atomic.make false in
  let live = Atomic.make [] in
    List.iter (fun (name, f) -> Lwt_host.attach host ~name f) (build ~bus ~entries ~live) ;
    { stop_flag; joined = Atomic.make false; owned_host = None; live }


let start ~bus ~entries () =
  let host = Lwt_host.create () in
  let t = attach ~host ~bus ~entries () in
    Lwt_host.start host ;
    { t with owned_host = Some host }


let stop t =
  if Atomic.compare_and_set t.joined false true then (
    Atomic.set t.stop_flag true ;
    match t.owned_host with None -> () | Some h -> Lwt_host.stop h) ;
  Atomic.get t.live


let live_stats t = Atomic.get t.live

let is_running t = not (Atomic.get t.joined)
