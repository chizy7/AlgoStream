(** Per-connection state machine: connect attempts, exponential backoff with jitter, circuit
    breaker, liveness tracking, and rate-limited Risk_alert emission.

    The mutable state is owned by a single Lwt fiber, so every function here except {!mirror} is NOT
    thread-safe across Domains. Observers on another Domain — a monitoring dashboard, say — must use
    {!mirror}, which reads an immutable record published on each transition. *)

type state =
  | Connecting
  | Connected
  | Reconnecting of {
      attempt : int;
      next_at_ns : int64;
    }
  | Open_circuit of { until_ns : int64 }

type t

val create :
  config:Algostream_common_config.Exchange_config.t ->
  bus:Algostream_infrastructure_event_bus.Event_bus.t ->
  unit ->
  t

val current_state : t -> state

val exchange : t -> string

val config : t -> Algostream_common_config.Exchange_config.t

val note_attempt : t -> unit

val note_connected : t -> unit

(** Records a failure and transitions to [Reconnecting] (or [Open_circuit] when the breaker trips).
    Optionally fires a Risk_alert with deduplication keyed on (code, symbol). *)
val note_failure : t -> reason:string -> ?symbol:string -> unit -> unit

val note_message : t -> unit

(** Time since the last successful frame read, in nanoseconds. [Int64.max_int] before the first
    message. *)
val time_since_last_message_ns : t -> int64

(** Whether a connect attempt may be made now — false during open-circuit. Pure, so it is safe to
    call from anywhere, including an observer. *)
val is_ready_to_attempt : t -> bool

(** As {!is_ready_to_attempt}, but {b advances the state machine}: an [Open_circuit] whose timer has
    expired is closed and returns to [Connecting]. This is the reconnect loop's entry point; use
    {!is_ready_to_attempt} to observe without side effects. *)
val poll_ready_to_attempt : t -> bool

(** How long to sleep before the next attempt; 0 if ready now. *)
val next_attempt_delay_ns : t -> int64

(** Returns true if there has been no inbound traffic for [read_timeout_ms]. Used to force a
    reconnect when the exchange goes silent. *)
val read_timed_out : t -> bool

(** Number of consecutive failures since the last successful connection. *)
val consecutive_failures : t -> int

(** Counts of dropped Critical-band alerts since the supervisor started — exposed for stats. *)
val critical_drops : t -> int64

(** Record a Critical-band publish failure that occurred outside this module. [Connector_runtime]
    calls it when a [Data_gap] is dropped — exactly the loss {!critical_drops} exists to surface. *)
val note_critical_drop : t -> unit

(** Cross-Domain-safe view of the connection.

    [state], [consecutive_failures] and [critical_drops] come from an immutable record republished
    on every transition; [time_since_last_message_ns] is computed at call time and is
    [Int64.max_int] before the first message. *)
type mirror = {
  exchange : string;
  state : state;
  consecutive_failures : int;
  critical_drops : int64;
  time_since_last_message_ns : int64;
}

val mirror : t -> mirror
