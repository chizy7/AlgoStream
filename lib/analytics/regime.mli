(** Threshold-based market regime detector.

    Four states with asymmetric dwell-time hysteresis: [Crisis] is sticky on entry and slow to leave
    (false-negative on Crisis is much worse than false-positive on Calm). All time arithmetic is in
    event-time (i.e. tick.timestamp_ns), never wall-clock — required for deterministic replay. *)

type t =
  | Calm
  | Trending of {
      direction : int; (* +1 up, -1 down *)
      strength : float; (* magnitude of recent return run *)
    }
  | Volatile
  | Crisis

val to_string : t -> string

val equal : t -> t -> bool

(* ───── detector ──────────────────────────────────────────────────── *)

type detector

val create : Config.t -> detector

(** Update the detector with the latest tick observations. Returns the current regime AFTER any
    transition. Time fields are in event-time nanoseconds; pass [tick.timestamp_ns] from the
    incoming tick. Never read wall-clock time inside the analytics path — replay determinism
    requires it. *)
val update :
  detector ->
  ts_ns:int64 ->
  ewma_vol:float ->
  vol_band_median:float ->
  drawdown_from_peak:float ->
  return_run_length:int ->
  return_run_sign:int ->
  t

val current : detector -> t

(** Nanoseconds spent in the current state, in event-time. *)
val dwell_ns : detector -> int64

(** Number of state transitions since detector creation. *)
val transitions : detector -> int
