(** Top-level Statistical Data Processing facade.

    Subscribes to the event bus (filtered to [Market_tick] / [Trade_print]), enqueues each incoming
    tick into a single-producer / single-consumer ring, and drains the ring on a dedicated
    [Domain.t] that owns all per-symbol state.

    Cross-Domain reads of analytics stats are race-free via [Snapshot.t Atomic.t] publication.
    Out-of-order ticks are dropped and counted (see [stats.out_of_order_drops]). Analytics state is
    bounded to [Config.t.max_active_symbols] symbols via LRU eviction.

    Concurrency invariant: this is the second [Domain.spawn] call site in the project after
    [Ingestion_supervisor]. The Analytics Domain does NOT call [Lwt_main.run]; it only does pure
    compute on dequeued ticks. *)

type t

type stats = {
  ticks_observed : int64;
  ticks_processed : int64;
  ticks_rejected_sanity : int64;
  ticks_rejected_outlier : int64;
  ticks_dropped_full_queue : int64;
  out_of_order_drops : int64;
  active_symbols : int;
  evictions : int64;
}

(** Spin up the Analytics Domain and subscribe to the bus. *)
val start : bus:Algostream_infrastructure_event_bus.Event_bus.t -> ?config:Config.t -> unit -> t

(** Signal stop, join the Analytics Domain, unsubscribe from bus. Safe to call twice. *)
val stop : t -> unit

(** Race-free per-symbol read. Returns [Snapshot.empty] for unknown symbols (including any that have
    been LRU-evicted). *)
val snapshot : t -> symbol:string -> Snapshot.t

(** Every symbol currently held, in no particular order. Symbols come and go as ticks arrive and the
    LRU evicts, so this is a point-in-time view — race-free, but stale the moment it returns. *)
val symbols : t -> string list

(** Snapshot of every held symbol. Allocates the list at call time; prefer {!snapshot} when the
    symbol is already known. *)
val snapshots : t -> Snapshot.t list

(** Convenience: rolling Pearson correlation of denoised price between [a] and [b].

    {b Not implemented — always returns 0.0.} Cross-symbol rolling correlation needs rolling stats
    shared across pairs, which this layer does not keep. Do not render this value; callers that need
    correlation should use [Algostream_pairs.Snapshot.corr], which is real. *)
val correlation : t -> a:string -> b:string -> float

val stats : t -> stats

val is_running : t -> bool
