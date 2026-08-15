(** Per-symbol analytics state.

    Owned and mutated exclusively by the Analytics Domain. Cross-Domain reads obtain a consistent
    immutable [Snapshot.t] via [snapshot]. *)

type t

val create : symbol:string -> config:Config.t -> t

(** Sole writer entry point. Runs the outlier pipeline, updates filters / rolling stats / volatility
    / regime, and republishes a [Snapshot.t] when the throttle allows. *)
val on_tick : t -> Tick_event.t -> unit

(** Lock-free, race-free read for cross-Domain consumers. *)
val snapshot : t -> Snapshot.t

(** Underlying atomic cell — exposed for [Processor] to hand out across Domains so reads stay O(1)
    without going through the symbol map. *)
val snapshot_atomic : t -> Snapshot.t Atomic.t

val symbol : t -> string

val last_event_ts_ns : t -> int64

val rejected_count : t -> int

val out_of_order_count : t -> int
