(** Single-Domain-owned per-pair state machine.

    Owns one pair's full state: hedge ratio, spread, rolling correlation, mean-reversion classifier,
    circular bar buffers for cointegration retesting, cached most-recent ADF / Engle-Granger /
    half-life results, and the [Snapshot.t Atomic.t] used for cross-Domain publication.

    All [on_tick] / [on_bar] calls must come from the same Domain (the pairs Processor's drain
    loop). [snapshot] / [snapshot_atomic] are the only cross-Domain reads — they touch the
    [Atomic.t] only. *)

module Bar = Algostream_time_series.Bar

type t

val create : pair:Pair_id.t -> config:Config.t -> t

(** Drop with [out_of_order_count] increment if [ts_ns < last_event_ts_ns]. Otherwise update the
    hedge ratio, correlation, spread, and mean-reversion signal; publish a fresh [Snapshot.t] if the
    event-time gap since the last publication is ≥ [config.min_publish_interval_ns]. *)
val on_tick : t -> y_price:float -> x_price:float -> ts_ns:int64 -> unit

(** Both bars must have the same [open_ts] — the processor is responsible for the alignment.
    Mis-aligned or out-of-order bars are silently ignored. When [bars_since_retest] reaches
    [config.coint_retest_bars] AND both buffers hold ≥ [config.coint_min_bars] samples, runs
    Engle-Granger and recomputes the half-life. *)
val on_bar : t -> y_bar:Bar.t -> x_bar:Bar.t -> unit

val snapshot : t -> Snapshot.t

val snapshot_atomic : t -> Snapshot.t Atomic.t

val pair : t -> Pair_id.t

val last_event_ts_ns : t -> int64

val out_of_order_count : t -> int

val n_ticks_processed : t -> int

val n_bars_processed : t -> int
