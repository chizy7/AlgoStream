open Base

(* High-performance timestamp interface compatible with Time_ns *)
type t = private float [@@deriving sexp, compare, hash]

(* Construction *)

(** Wall-clock read. Backed by [Unix.time ()], so the resolution is {b whole seconds} — adequate for
    stamping long-lived records, useless for intra-second ordering. Event-time-deterministic layers
    (backtest, analytics, time_series, pairs, …) must never call this; they pass explicit [ts_ns]
    through {!of_ns}. *)
val now : unit -> t

val of_float : float -> t

val of_sec_float : float -> t

val of_ms_float : float -> t

val of_us_float : float -> t

(** Build a timestamp from nanoseconds since the epoch — the event-time representation carried by
    [Event.t.timestamp_ns], [Bar.t.open_ts], and every [~ts_ns] parameter in the analytical layers.

    {b Precision.} [t] is a float64 count of {i seconds} since the epoch. At present-day epoch
    values (~1.8e9 s) the 53-bit mantissa resolves to roughly 240 ns, so [of_ns] is not exactly
    invertible by {!to_ns} at nanosecond granularity. That is well inside bar- and tick-level
    backtesting needs; do not use these for latency accounting, where
    [Time_utils.Clock.now_monotonic_ns] and raw [int64] ns are the right tools. *)
val of_ns : int64 -> t

(* Conversion *)
val to_float : t -> float

val to_sec_float : t -> float

val to_ms_float : t -> float

val to_us_float : t -> float

(** Inverse of {!of_ns}, rounded to nearest. Subject to the same ~240 ns precision floor. *)
val to_ns : t -> int64

val to_string : t -> string

(* Constants *)
val epoch : t

(* Arithmetic *)
val diff : t -> t -> float

val add : t -> float -> t

val sub : t -> float -> t

val ( + ) : t -> float -> t

val ( - ) : t -> float -> t

(* Comparison *)
val equal : t -> t -> bool

val ( = ) : t -> t -> bool

val ( <> ) : t -> t -> bool

val ( < ) : t -> t -> bool

val ( <= ) : t -> t -> bool

val ( > ) : t -> t -> bool

val ( >= ) : t -> t -> bool

val compare : t -> t -> int

val min : t -> t -> t

val max : t -> t -> t

(* Span module for time differences *)
module Span : sig
  type t = private float [@@deriving sexp, compare, hash]

  (* Construction *)
  val of_sec : float -> t

  val of_min : float -> t

  val of_hr : float -> t

  val of_day : float -> t

  val of_ms : float -> t

  val of_us : float -> t

  (* Conversion *)
  val to_sec : t -> float

  val to_min : t -> float

  val to_hr : t -> float

  val to_day : t -> float

  val to_ms : t -> float

  val to_us : t -> float

  val to_string : t -> string

  (* Constants *)
  val zero : t

  (* Arithmetic *)
  val ( + ) : t -> t -> t

  val ( - ) : t -> t -> t

  val ( * ) : t -> float -> t

  val ( / ) : t -> float -> t

  (* Comparison *)
  val compare : t -> t -> int
end

(* Constants *)
module Span_constants : sig
  val nanosecond : float

  val microsecond : float

  val millisecond : float

  val second : float

  val minute : float

  val hour : float

  val day : float
end
