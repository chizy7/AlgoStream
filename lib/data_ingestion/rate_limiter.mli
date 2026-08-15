(** Token-bucket rate limiter for outbound WebSocket control frames.

    Two buckets share refill: the main bucket is consumed by [try_take ()]; the reserved bucket is
    only consumed by [try_take ~reserved:true] (used for pong replies so heartbeat traffic cannot be
    starved by a resubscribe storm). Time is taken from the supplied clock — defaults to
    [Time_utils.Clock.now_monotonic_ns]. *)

type t

val create :
  ?clock_ns:(unit -> int64) -> capacity:int -> refill_per_sec:int -> reserved:int -> unit -> t

(** Attempt to consume one token. When [reserved] is true, draws from the reserved sub-bucket first,
    falling back to the main bucket. *)
val try_take : ?reserved:bool -> t -> bool

val available : t -> int

val available_reserved : t -> int
