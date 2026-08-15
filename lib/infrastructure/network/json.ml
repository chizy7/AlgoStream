module TS = Algostream_telemetry.Snapshot
module TH = Algostream_telemetry.Histogram
module Health = Algostream_telemetry.Health
module Alert = Algostream_telemetry.Alert
module RS = Algostream_runtime.Snapshot
module Side = Algostream_strategy.Side
module Trade = Algostream_domain_trades.Trade

type t = Yojson.Safe.t

(* The guard that matters: Yojson emits bare NaN/Infinity, which no JSON parser accepts. *)
let float (v : float) : t = if Float.is_finite v then `Float v else `Null

let int v : t = `Int v

let int64 v : t = `Intlit (Int64.to_string v)

let string v : t = `String v

let bool v : t = `Bool v

let obj kvs : t = `Assoc kvs

let list f xs : t = `List (List.map f xs)

let array f xs : t = `List (Array.to_list (Array.map f xs))

let opt f = function None -> `Null | Some x -> f x

let of_assoc kvs : t = `Assoc (List.map (fun (k, v) -> (k, float v)) kvs)

let to_string (j : t) = Yojson.Safe.to_string j

let error msg : t = `Assoc [ ("error", `String msg) ]

let of_histogram_summary (s : TH.summary) =
  obj
    [
      ("count", int64 s.TH.count);
      ("mean_ns", float s.TH.mean_ns);
      ("p50_ns", int64 s.TH.p50_ns);
      ("p90_ns", int64 s.TH.p90_ns);
      ("p99_ns", int64 s.TH.p99_ns);
      ("p999_ns", int64 s.TH.p999_ns);
      ("max_ns", int64 s.TH.max_ns);
    ]


let of_health_status (s : Health.status) =
  match s with
  | Health.Ok -> obj [ ("state", string "ok"); ("reason", `Null) ]
  | Health.Degraded r -> obj [ ("state", string "degraded"); ("reason", string r) ]
  | Health.Failed r -> obj [ ("state", string "failed"); ("reason", string r) ]


let of_alert (a : Alert.t) =
  obj
    [
      ("code", string a.Alert.code);
      ("severity", string (Alert.severity_to_string a.Alert.severity));
      ("message", string a.Alert.message);
      ("first_raised_ns", int64 a.Alert.first_raised_ns);
      ("last_raised_ns", int64 a.Alert.last_raised_ns);
      ("count", int a.Alert.count);
    ]


let of_health_report (r : Health.report) =
  obj
    [
      ("name", string r.Health.check_name);
      ("status", of_health_status r.Health.status);
      ("checked_at_ns", int64 r.Health.checked_at_ns);
    ]


let of_component (c : TS.component) =
  obj
    [
      ("name", string c.TS.name);
      ("status", of_health_status c.TS.status);
      ("metrics", of_assoc c.TS.metrics);
    ]


let of_telemetry (s : TS.t) =
  obj
    [
      ("ts_ns", int64 s.TS.ts_ns);
      ("wall_ns", int64 s.TS.wall_ns);
      ("uptime_ns", int64 s.TS.uptime_ns);
      ("overall", of_health_status s.TS.overall);
      ( "latency",
        obj
          [
            ("end_to_end", of_histogram_summary s.TS.latency.TS.end_to_end);
            ("sla_ns", int64 s.TS.latency.TS.sla_ns);
            ("sla_violations", int64 s.TS.latency.TS.sla_violations);
            ("sla_violation_pct", float s.TS.latency.TS.sla_violation_pct);
          ] );
      ( "bus",
        obj
          [
            ("depth", int s.TS.bus.TS.depth);
            ("depth_per_band", array int s.TS.bus.TS.depth_per_band);
            ("subscribers", int s.TS.bus.TS.subscriber_count);
            ("published", int64 s.TS.bus.TS.published);
            ("dropped", int64 s.TS.bus.TS.dropped);
            ("dropped_per_band", array int64 s.TS.bus.TS.dropped_per_band);
            ("dispatched", int64 s.TS.bus.TS.dispatched);
            ("handler_errors", int64 s.TS.bus.TS.handler_errors);
            ("events_per_sec", float s.TS.bus.TS.events_per_sec);
          ] );
      ("components", list of_component s.TS.components);
      ("health", list of_health_report s.TS.health);
      ("alerts", list of_alert s.TS.alerts);
    ]


let of_position (p : RS.position) =
  obj
    [
      ("symbol", string p.RS.symbol);
      ("quantity", float p.RS.quantity);
      ("average_price", float p.RS.average_price);
      ("market_value", float p.RS.market_value);
      ("unrealized_pnl", float p.RS.unrealized_pnl);
    ]


let of_fill (f : RS.fill) =
  obj
    [
      ("ts_ns", int64 f.RS.ts_ns);
      ("order_id", string f.RS.order_id);
      ("client_order_id", string f.RS.client_order_id);
      ("symbol", string f.RS.symbol);
      ("side", string (Side.to_string f.RS.side));
      ("quantity", float f.RS.quantity);
      ("price", float f.RS.price);
      ("commission", float f.RS.commission);
      ( "liquidity",
        string
          (match f.RS.liquidity with
          | Trade.Maker -> "maker"
          | Trade.Taker -> "taker"
          | Trade.Self_trade -> "self_trade") );
      ("tag", string f.RS.tag);
    ]


let of_runtime_instance (i : RS.instance) =
  obj
    [
      ("strategy_id", string i.RS.strategy_id);
      ("name", string i.RS.strategy_name);
      ("version", string i.RS.strategy_version);
      ("lifecycle", string (RS.lifecycle_to_string i.RS.lifecycle));
      ("allocation", float i.RS.allocation);
      ("nav", float i.RS.nav);
      ("cash", float i.RS.cash);
      ("realized_pnl", float i.RS.realized_pnl);
      ("unrealized_pnl", float i.RS.unrealized_pnl);
      ("gross_exposure", float i.RS.gross_exposure);
      ("net_exposure", float i.RS.net_exposure);
      ("leverage", float i.RS.leverage);
      ("positions", list of_position i.RS.positions);
      ("working_orders", int i.RS.working_orders);
      ( "counters",
        obj
          [
            ("events", int i.RS.n_events);
            ("actions", int i.RS.n_actions);
            ("submitted", int i.RS.n_submitted);
            ("rejected_by_risk", int i.RS.n_rejected_by_risk);
            ("fills", int i.RS.n_fills);
          ] );
      ("recent_fills", list of_fill i.RS.recent_fills);
      ("diagnostics", of_assoc i.RS.diagnostics);
      ("params", of_assoc i.RS.params);
      ("last_event_ts_ns", int64 i.RS.last_event_ts_ns);
    ]


let of_runtime (s : RS.t) =
  obj
    [
      ("ts_ns", int64 s.RS.ts_ns);
      ("total_nav", float s.RS.total_nav);
      ("total_allocation", float s.RS.total_allocation);
      ("events", int s.RS.n_events);
      ("dropped_full_queue", int s.RS.n_dropped_full_queue);
      ("instances", list of_runtime_instance s.RS.instances);
      (* Stated in the payload, not only in the UI: everything above is simulated. *)
      ("mode", string "paper");
    ]


let of_series xs = array (fun (ts, v) -> `List [ int64 ts; float v ]) xs
