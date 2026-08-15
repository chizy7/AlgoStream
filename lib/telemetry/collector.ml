module Event_bus = Algostream_infrastructure_event_bus.Event_bus
module Subscription = Algostream_infrastructure_event_bus.Subscription
module Clock = Algostream_common_utils.Time_utils.Clock

type provider = {
  name : string;
  metrics : unit -> (string * float) list;
  health : (unit -> Health.status) option;
}

type t = {
  bus : Event_bus.t;
  sla_ns : int64;
  latency : Histogram.t;
  started_ns : int64;
  providers : provider list Atomic.t;
  checks : Health.check list Atomic.t;
  alerts : Alert.registry;
  subscription : Subscription.subscription_id option Atomic.t;
  (* (sampled_at_ns, dispatched_count) from the previous snapshot, for the rate derivation. *)
  rate_prev : (int64 * int64) Atomic.t;
  latency_alerting : bool Atomic.t;
}

let default_sla_ns = 5_000_000L

let create ~bus ?(sla_ns = default_sla_ns) ?alert_window_ns () =
  {
    bus;
    sla_ns;
    latency = Histogram.create ();
    started_ns = Clock.now_monotonic_ns ();
    providers = Atomic.make [];
    checks = Atomic.make [];
    alerts = Alert.create ?window_ns:alert_window_ns ();
    subscription = Atomic.make None;
    rate_prev = Atomic.make (0L, 0L);
    latency_alerting = Atomic.make true;
  }


let rec push_atomic a x =
  let cur = Atomic.get a in
    if Atomic.compare_and_set a cur (x :: cur) then () else push_atomic a x


let set_latency_alerting t v = Atomic.set t.latency_alerting v

let latency_alerting t = Atomic.get t.latency_alerting

let register t p = push_atomic t.providers p

let add_check t c = push_atomic t.checks c

let alerts t = t.alerts

let latency_histogram t = t.latency

(* The whole of the bus-facing work. Two atomics, no allocation, no payload inspection — this runs
   inline on the dispatcher Domain for every event and every other subscriber pays for it. *)
let handler t (event : Algostream_infrastructure_event_bus.Event_types.Event.t) =
  Histogram.record t.latency (Int64.sub (Clock.now_monotonic_ns ()) event.timestamp_ns)


let start t =
  match Atomic.get t.subscription with
  | Some _ -> ()
  | None ->
    let id = Event_bus.subscribe t.bus (fun e -> handler t e) in
      if not (Atomic.compare_and_set t.subscription None (Some id)) then
        (* Lost a race with another [start]; drop the duplicate subscription rather than leaking
           it. *)
        Event_bus.unsubscribe t.bus id


let stop t =
  match Atomic.get t.subscription with
  | None -> ()
  | Some id as cur ->
    if Atomic.compare_and_set t.subscription cur None then Event_bus.unsubscribe t.bus id


let is_running t = Atomic.get t.subscription <> None

let reset t =
  Histogram.reset t.latency ;
  Atomic.set t.rate_prev (0L, 0L)


let events_per_sec t ~now_ns ~dispatched =
  (* Keep the value we read: [Atomic.compare_and_set] on a boxed tuple compares physically, so
     rebuilding an equal tuple from the destructured parts would never match and the previous sample
     would never advance — leaving the rate pinned at zero. *)
  let prev = Atomic.get t.rate_prev in
  let prev_ns, prev_count = prev in
  let rate =
    if Int64.equal prev_ns 0L then 0.0
    else
      let dt = Int64.to_float (Int64.sub now_ns prev_ns) /. 1e9 in
      let dn = Int64.to_float (Int64.sub dispatched prev_count) in
        if dt <= 0.0 then 0.0 else dn /. dt in
    (* Best-effort: if another caller updated it first, our rate is still valid for this call. *)
    ignore (Atomic.compare_and_set t.rate_prev prev (now_ns, dispatched) : bool) ;
    rate


(* Rules the collector owns itself. Everything else raises into the registry from outside. *)
let evaluate_alerts t ~ts_ns ~(latency : Snapshot.latency) ~(bus : Snapshot.bus) =
  let set cond ~code ~severity ~message =
    if cond then ignore (Alert.raise_alert t.alerts ~ts_ns ~code ~severity ~message : bool)
    else ignore (Alert.clear t.alerts ~code : bool) in
    set
      (Atomic.get t.latency_alerting
      && Int64.compare latency.end_to_end.Histogram.p99_ns t.sla_ns > 0)
      ~code:"LATENCY_SLA" ~severity:Alert.Critical
      ~message:
        (Printf.sprintf "p99 end-to-end %Ldns exceeds the %Ldns SLA"
           latency.end_to_end.Histogram.p99_ns t.sla_ns) ;
    let drop_pct =
      if Int64.equal bus.published 0L then 0.0
      else Int64.to_float bus.dropped /. Int64.to_float bus.published *. 100.0 in
      set (drop_pct > 0.1) ~code:"BUS_DROPS" ~severity:Alert.Warning
        ~message:(Printf.sprintf "%.3f%% of publishes dropped (%Ld events)" drop_pct bus.dropped) ;
      set
        (Int64.compare bus.handler_errors 0L > 0)
        ~code:"HANDLER_ERRORS" ~severity:Alert.Warning
        ~message:
          (Printf.sprintf "%Ld subscriber handler exceptions — a subscriber may be dead"
             bus.handler_errors)


let snapshot t =
  let ts_ns = Clock.now_monotonic_ns () in
  let flow = Event_bus.flow_stats t.bus in
  let hist = Histogram.summary t.latency in
  let violations = Histogram.count_at_or_above t.latency t.sla_ns in
  let violation_pct =
    if Int64.equal hist.Histogram.count 0L then 0.0
    else Int64.to_float violations /. Int64.to_float hist.Histogram.count *. 100.0 in
  let latency =
    {
      Snapshot.end_to_end = hist;
      sla_ns = t.sla_ns;
      sla_violations = violations;
      sla_violation_pct = violation_pct;
    } in
  let bus =
    {
      Snapshot.depth = Event_bus.depth t.bus;
      depth_per_band = Event_bus.depth_per_band t.bus;
      subscriber_count = Event_bus.subscriber_count t.bus;
      published = flow.Event_bus.total_published;
      dropped = flow.Event_bus.total_dropped;
      dropped_per_band = flow.Event_bus.dropped_per_band;
      dispatched = flow.Event_bus.dispatched;
      handler_errors = flow.Event_bus.handler_errors;
      events_per_sec = events_per_sec t ~now_ns:ts_ns ~dispatched:flow.Event_bus.dispatched;
    } in
  let components =
    List.rev_map
      (fun p ->
        let metrics = try p.metrics () with _ -> [] in
        let status =
          match p.health with
          | None -> Health.Ok
          | Some f ->
            (try f ()
             with exn ->
               Health.Failed (Printf.sprintf "provider raised: %s" (Printexc.to_string exn))) in
          { Snapshot.name = p.name; metrics; status })
      (Atomic.get t.providers) in
  let health = Health.run_all (List.rev (Atomic.get t.checks)) ~ts_ns in
  let component_statuses = List.map (fun (c : Snapshot.component) -> c.Snapshot.status) components in
    evaluate_alerts t ~ts_ns ~latency ~bus ;
    {
      Snapshot.ts_ns;
      wall_ns = Clock.now_realtime_ns ();
      uptime_ns = Int64.sub ts_ns t.started_ns;
      latency;
      bus;
      components;
      health;
      overall = Health.worst (Health.overall health :: component_statuses);
      alerts = Alert.active t.alerts;
    }
