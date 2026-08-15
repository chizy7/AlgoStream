(** Spread tracker: [s_t = y_t − β·x_t − α], with rolling mean / std / z-score.

    Mean and variance use the existing [Rolling_mean] / [Rolling_var] primitives — the
    periodic-recompute trick keeps long-running std-devs from drifting due to floating-point
    cancellation. *)

type t

val create : window:int -> recompute_every:int -> t

val update : t -> y:float -> x:float -> beta:float -> intercept:float -> ts_ns:int64 -> unit

val current : t -> float

val mean : t -> float

val std : t -> float

val z : t -> float

val n : t -> int

val last_ts_ns : t -> int64
