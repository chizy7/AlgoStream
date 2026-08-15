module Clock = Algostream_common_utils.Time_utils.Clock
module Event_bus = Algostream_infrastructure_event_bus.Event_bus
module Event_types = Algostream_infrastructure_event_bus.Event_types
module Exchange_config = Algostream_common_config.Exchange_config

type state =
  | Connecting
  | Connected
  | Reconnecting of {
      attempt : int;
      next_at_ns : int64;
    }
  | Open_circuit of { until_ns : int64 }

type mirror = {
  exchange : string;
  state : state;
  consecutive_failures : int;
  critical_drops : int64;
  time_since_last_message_ns : int64;
}

(* What is actually stored in the atomic. Liveness is deliberately absent: it changes on every
   message, so it lives in its own atomic and is stitched in by [mirror] at read time. *)
type published = {
  p_state : state;
  p_failures : int;
  p_critical_drops : int64;
}

type t = {
  config : Exchange_config.t;
  bus : Event_bus.t;
  mutable state : state;
  mutable consecutive_failures : int;
  last_msg_ns : int Atomic.t;
    (** Monotonic ns, or [-1] before the first message. An [int Atomic.t] rather than a mutable
        [int64] field for two reasons: it is written on every inbound message, where boxing an int64
        would allocate on the hot path; and it is read from other Domains by the mirror, where a
        plain mutable field would be a data race. *)
  alert_dedup : (string * string, int64) Hashtbl.t;
  alert_dedup_window_ns : int64;
  mutable critical_drops : int64;
  pub : published Atomic.t;
    (** Immutable mirror of the fields that only change on state transitions, so observers on other
        Domains never touch the mutable record. *)
}

let alert_log_src = Logs.Src.create "algostream.data_ingestion.connection"

module Log = (val Logs.src_log alert_log_src : Logs.LOG)

let ms_to_ns ms = Int64.of_int (ms * 1_000_000)

let create ~config ~bus () =
  {
    config;
    bus;
    state = Connecting;
    consecutive_failures = 0;
    last_msg_ns = Atomic.make (-1);
    alert_dedup = Hashtbl.create 16;
    alert_dedup_window_ns = 30_000_000_000L;
    critical_drops = 0L;
    pub = Atomic.make { p_state = Connecting; p_failures = 0; p_critical_drops = 0L };
  }


let current_state t = t.state

let exchange t = t.config.name

let config t = t.config

let consecutive_failures t = t.consecutive_failures

let critical_drops t = t.critical_drops

let time_since_last_message_ns t =
  match Atomic.get t.last_msg_ns with
  | -1 -> Int64.max_int
  | ns -> Int64.sub (Clock.now_monotonic_ns ()) (Int64.of_int ns)


(* Called after every transition. Cheap: transitions are rare compared to messages. *)
let publish_mirror t =
  Atomic.set t.pub
    { p_state = t.state; p_failures = t.consecutive_failures; p_critical_drops = t.critical_drops }


let mirror t =
  let p = Atomic.get t.pub in
    {
      exchange = t.config.name;
      state = p.p_state;
      consecutive_failures = p.p_failures;
      critical_drops = p.p_critical_drops;
      time_since_last_message_ns = time_since_last_message_ns t;
    }


let publish_critical_dedup t ~code ~symbol ~message ~severity =
  let now = Clock.now_monotonic_ns () in
  let key = (code, Option.value symbol ~default:"") in
  let allow =
    match Hashtbl.find_opt t.alert_dedup key with
    | Some last when Int64.sub now last < t.alert_dedup_window_ns -> false
    | _ -> true in
    if allow then (
      Hashtbl.replace t.alert_dedup key now ;
      let payload = Event_types.Event.Risk_alert { code; message; severity } in
      let event =
        Event_types.Event.create ~source:t.config.name ~priority:Event_types.Priority.Critical
          payload in
        if not (Event_bus.try_publish t.bus event) then (
          t.critical_drops <- Int64.add t.critical_drops 1L ;
          publish_mirror t ;
          Log.err (fun m -> m "[%s] critical-band drop: %s %s" t.config.name code message)))


(* Records a Critical-band drop that happened outside this module — Connector_runtime drops Data_gap
   events, which are the signal this counter exists to protect. Before this existed [critical_drops]
   counted only dropped CIRCUIT_OPEN/RECONNECT alerts, despite the caller's comment claiming
   otherwise. *)
let note_critical_drop t =
  t.critical_drops <- Int64.add t.critical_drops 1L ;
  publish_mirror t


let backoff_with_jitter ~attempt t =
  let p = t.config.retry in
  let exp_factor = 1 lsl min attempt 16 in
  let raw = p.base_backoff_ms * exp_factor in
  let capped = min raw p.max_backoff_ms in
  let jitter_amount = float_of_int capped *. p.jitter_pct in
  let jitter = ((Random.float 1.0 *. 2.0) -. 1.0) *. jitter_amount in
  let final_ms = max 1 (int_of_float (float_of_int capped +. jitter)) in
    ms_to_ns final_ms


let note_attempt t =
  t.state <- Connecting ;
  publish_mirror t


let note_connected t =
  t.consecutive_failures <- 0 ;
  t.state <- Connected ;
  Atomic.set t.last_msg_ns (Int64.to_int (Clock.now_monotonic_ns ())) ;
  publish_mirror t


let note_failure t ~reason ?symbol () =
  t.consecutive_failures <- t.consecutive_failures + 1 ;
  let now = Clock.now_monotonic_ns () in
    if t.consecutive_failures >= t.config.retry.circuit_breaker_threshold then (
      let until = Int64.add now (ms_to_ns t.config.retry.circuit_open_ms) in
        t.state <- Open_circuit { until_ns = until } ;
        publish_mirror t ;
        publish_critical_dedup t ~code:"CIRCUIT_OPEN" ~symbol
          ~message:
            (Printf.sprintf "%s circuit open after %d failures: %s" t.config.name
               t.consecutive_failures reason)
          ~severity:3)
    else
      let delay_ns = backoff_with_jitter ~attempt:t.consecutive_failures t in
      let next_at = Int64.add now delay_ns in
        t.state <- Reconnecting { attempt = t.consecutive_failures; next_at_ns = next_at } ;
        publish_mirror t ;
        publish_critical_dedup t ~code:"RECONNECT" ~symbol
          ~message:
            (Printf.sprintf "%s reconnect attempt %d after %.1fs: %s" t.config.name
               t.consecutive_failures
               (Int64.to_float delay_ns /. 1_000_000_000.0)
               reason)
          ~severity:2


let note_message t = Atomic.set t.last_msg_ns (Int64.to_int (Clock.now_monotonic_ns ()))

(* Pure. Safe for observers; does not advance the circuit. *)
let is_ready_to_attempt t =
  match t.state with
  | Connecting | Connected -> true
  | Reconnecting { next_at_ns; _ } -> Int64.compare (Clock.now_monotonic_ns ()) next_at_ns >= 0
  | Open_circuit { until_ns } -> Int64.compare (Clock.now_monotonic_ns ()) until_ns >= 0


(* Not pure: when the circuit timer has expired this closes it and returns to [Connecting]. That
   transition has to happen somewhere, and the reconnect loop is the only caller — but the old name
   [ready_to_attempt] read like a query, so the mutation was invisible at the call site. *)
let poll_ready_to_attempt t =
  match t.state with
  | Open_circuit { until_ns } when Int64.compare (Clock.now_monotonic_ns ()) until_ns >= 0 ->
    t.consecutive_failures <- 0 ;
    t.state <- Connecting ;
    publish_mirror t ;
    true
  | _ -> is_ready_to_attempt t


let next_attempt_delay_ns t =
  match t.state with
  | Connecting | Connected -> 0L
  | Reconnecting { next_at_ns; _ } ->
    let now = Clock.now_monotonic_ns () in
      if Int64.compare next_at_ns now <= 0 then 0L else Int64.sub next_at_ns now
  | Open_circuit { until_ns } ->
    let now = Clock.now_monotonic_ns () in
      if Int64.compare until_ns now <= 0 then 0L else Int64.sub until_ns now


let read_timed_out t =
  match t.state with
  | Connected ->
    Int64.compare (time_since_last_message_ns t) (ms_to_ns t.config.retry.read_timeout_ms) > 0
  | _ -> false
