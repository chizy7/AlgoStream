type latency = {
  end_to_end : Histogram.summary;
  sla_ns : int64;
  sla_violations : int64;
  sla_violation_pct : float;
}

type bus = {
  depth : int;
  depth_per_band : int array;
  subscriber_count : int;
  published : int64;
  dropped : int64;
  dropped_per_band : int64 array;
  dispatched : int64;
  handler_errors : int64;
  events_per_sec : float;
}

type component = {
  name : string;
  metrics : (string * float) list;
  status : Health.status;
}

type t = {
  ts_ns : int64;
  wall_ns : int64;
  uptime_ns : int64;
  latency : latency;
  bus : bus;
  components : component list;
  health : Health.report list;
  overall : Health.status;
  alerts : Alert.t list;
}

let band_name i =
  match i with 0 -> "critical" | 1 -> "high" | 2 -> "normal" | 3 -> "low" | n -> string_of_int n


let to_assoc t =
  let h = t.latency.end_to_end in
  let base =
    [
      ("uptime_s", Int64.to_float t.uptime_ns /. 1e9);
      ("latency.count", Int64.to_float h.Histogram.count);
      ("latency.mean_ns", h.Histogram.mean_ns);
      ("latency.p50_ns", Int64.to_float h.Histogram.p50_ns);
      ("latency.p90_ns", Int64.to_float h.Histogram.p90_ns);
      ("latency.p99_ns", Int64.to_float h.Histogram.p99_ns);
      ("latency.p999_ns", Int64.to_float h.Histogram.p999_ns);
      ("latency.max_ns", Int64.to_float h.Histogram.max_ns);
      ("latency.sla_ns", Int64.to_float t.latency.sla_ns);
      ("latency.sla_violations", Int64.to_float t.latency.sla_violations);
      ("latency.sla_violation_pct", t.latency.sla_violation_pct);
      ("bus.depth", float_of_int t.bus.depth);
      ("bus.subscribers", float_of_int t.bus.subscriber_count);
      ("bus.published", Int64.to_float t.bus.published);
      ("bus.dropped", Int64.to_float t.bus.dropped);
      ("bus.dispatched", Int64.to_float t.bus.dispatched);
      ("bus.handler_errors", Int64.to_float t.bus.handler_errors);
      ("bus.events_per_sec", t.bus.events_per_sec);
    ] in
  let bands =
    Array.to_list
      (Array.mapi
         (fun i d -> (Printf.sprintf "bus.depth.%s" (band_name i), float_of_int d))
         t.bus.depth_per_band)
    @ Array.to_list
        (Array.mapi
           (fun i d -> (Printf.sprintf "bus.dropped.%s" (band_name i), Int64.to_float d))
           t.bus.dropped_per_band) in
  let comps =
    List.concat_map
      (fun c -> List.map (fun (k, v) -> (Printf.sprintf "%s.%s" c.name k, v)) c.metrics)
      t.components in
    base @ bands @ comps


let to_string t =
  let b = Buffer.create 1024 in
  let add fmt = Printf.ksprintf (Buffer.add_string b) fmt in
    add "telemetry @ %.1fs uptime — %s\n"
      (Int64.to_float t.uptime_ns /. 1e9)
      (Health.status_to_string t.overall) ;
    add "  latency  %s\n" (Histogram.summary_to_string t.latency.end_to_end) ;
    add "           sla %Ldns violated %Ld times (%.3f%%)\n" t.latency.sla_ns
      t.latency.sla_violations t.latency.sla_violation_pct ;
    add "  bus      depth=%d subs=%d pub=%Ld drop=%Ld disp=%Ld errs=%Ld %.0f ev/s\n" t.bus.depth
      t.bus.subscriber_count t.bus.published t.bus.dropped t.bus.dispatched t.bus.handler_errors
      t.bus.events_per_sec ;
    List.iter
      (fun c ->
        add "  %-12s %s\n" c.name (Health.status_to_string c.status) ;
        List.iter (fun (k, v) -> add "               %-28s %.4g\n" k v) c.metrics)
      t.components ;
    List.iter
      (fun (r : Health.report) ->
        add "  check    %-24s %s\n" r.Health.check_name (Health.status_to_string r.Health.status))
      t.health ;
    List.iter (fun a -> add "  alert    %s\n" (Alert.to_string a)) t.alerts ;
    Buffer.contents b
