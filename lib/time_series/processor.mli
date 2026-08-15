(** Top-level Time Series facade.

    Subscribes to the event bus (filtered to [Market_tick] / [Trade_print]), enqueues each tick into
    a single-producer/single-consumer ring, and drains the ring on a dedicated [Domain.t] that owns
    all per-(symbol, interval) [BarBuilder] state.

    Cross-Domain reads of bar history are race-free via [Atomic.set] of an immutable [Bar.t array].
    Same pattern as the analytics layer.

    All time arithmetic uses [tick.timestamp_ns]; never reads wall-clock — replay determinism. *)

type t

type stats = {
  ticks_observed : int64;
  ticks_processed : int64;
  ticks_rejected_sanity : int64;
  ticks_dropped_full_queue : int64;
  bars_emitted : int64;
  late_ticks : int64;
  active_keys : int; (* (symbol, interval) pairs *)
}

(** Start the processor.

    [intervals_ns]: default [[1_000_000_000L]] (1s). Multiple intervals fan out per-symbol — e.g.
    [[1_000_000_000L; 60_000_000_000L]] gives both 1s and 1m bars per symbol.

    [ring_size]: number of recent bars retained per (symbol, interval). Default 1024.

    [max_active_keys]: LRU cap on (symbol, interval) pairs. Default 256. *)
val start :
  bus:Algostream_infrastructure_event_bus.Event_bus.t ->
  ?intervals_ns:int64 list ->
  ?ring_size:int ->
  ?max_active_keys:int ->
  unit ->
  t

val stop : t -> unit

(** Race-free read of the most recent bars for [(symbol, interval_ns)]. Returns [None] if no ticks
    have been seen for that pair. The returned array is a fresh, immutable snapshot of the last
    up-to-[ring_size] bars (newest last). *)
val bars : t -> symbol:string -> interval_ns:int64 -> Bar.t array option

(** Every [(symbol, interval_ns)] pair currently held, in no particular order. Point-in-time: keys
    appear as ticks arrive and disappear on LRU eviction. *)
val keys : t -> (string * int64) list

val stats : t -> stats

val is_running : t -> bool
