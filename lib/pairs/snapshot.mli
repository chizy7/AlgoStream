(** Immutable per-pair snapshot.

    The pairs Processor allocates a fresh [t] per per-pair update and publishes it via [Atomic.set]
    into a per-pair [t Atomic.t]. Downstream strategies read via [Atomic.get] — release-acquire
    ordering is sufficient because [t] itself never mutates after publication.

    [signal] is the most recent [Mean_reversion.signal] returned by the per-pair classifier.
    [cointegrated], [adf_*], [half_life_bars] reflect the most recent bar-cadence retest (or cleared
    defaults if no retest has fired yet). *)

type t = {
  pair : Pair_id.t;
  last_event_ts_ns : int64;
  n_ticks : int;
  n_bars : int;
  last_price_y : float;
  last_price_x : float;
  beta : float;
  beta_stdev : float;
  intercept : float;
  spread : float;
  spread_mean : float;
  spread_std : float;
  z_score : float;
  corr : float;
  adf_t_stat : float;
  adf_p_value : float;
  cointegrated : bool;
  half_life_bars : float;
  avg_volume : float;
  signal : Mean_reversion.signal;
  ready : bool;
}

val empty : pair:Pair_id.t -> t

val to_string : t -> string
