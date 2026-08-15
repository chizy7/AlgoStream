(** Pairs Trading facade.

    Subscribes to the event bus (filtered to [Market_tick] / [Trade_print]), enqueues each incoming
    tick whose symbol is part of a tracked pair into a single-producer / single-consumer ring, and
    drains the ring on a dedicated [Domain.t] that owns all per-pair state.

    Bars are admin-fed via [feed_bar] — bars are not yet on the bus (the time-series Processor
    exposes snapshots, not bus events). A future PR will add a bar-publisher bridge.

    Cross-Domain reads of [Snapshot.t] are race-free via [Atomic.t] publication. *)

module Bar = Algostream_time_series.Bar

type t

type pair_spec = {
  pair : Pair_id.t;
  y_raw : string;  (** exchange-native symbol arriving on the bus for the y leg *)
  x_raw : string;  (** exchange-native symbol arriving on the bus for the x leg *)
}

type stats = {
  ticks_observed : int64;
  ticks_processed : int64;
  bars_processed : int64;
  ticks_dropped_full_queue : int64;
  out_of_order_drops : int64;
  active_pairs : int;
}

(** Spin up the Pairs Domain and subscribe to the bus. Raises [Invalid_argument] if
    [List.length pairs > config.max_active_pairs]. *)
val start :
  bus:Algostream_infrastructure_event_bus.Event_bus.t ->
  pairs:pair_spec list ->
  ?config:Config.t ->
  unit ->
  t

(** Signal stop, join the Pairs Domain, unsubscribe from the bus. Safe to call twice. *)
val stop : t -> unit

(** Race-free per-pair read. Returns [Snapshot.empty] for unknown pairs. *)
val snapshot : t -> pair:Pair_id.t -> Snapshot.t

(** Collect a snapshot of every tracked pair. Allocates the list at call time. *)
val snapshots : t -> Snapshot.t list

(** Admin entry: enqueue a closed bar for processing. The Domain caches the bar by symbol and fires
    [Per_pair.on_bar] only when both legs of any containing pair have bars with the same [open_ts].
    Drops the bar (and counts the drop) on a full queue. *)
val feed_bar : t -> Bar.t -> unit

val stats : t -> stats

val is_running : t -> bool
