(** Tunable parameters for the pairs trading layer.

    All time arithmetic in this layer is event-time only — there are no wall-clock reads. CI lint
    enforces that. *)

type adf_variant =
  | No_constant
  | With_constant
  | With_trend

type beta_mode =
  | Static of float
  | Rolling_ols
  | Kalman_smoothed

type t = {
  (* rolling-window primitives *)
  corr_window : int;
  spread_window : int;
  beta_window : int;
  recompute_every : int;
  (* hedge ratio *)
  beta_mode : beta_mode;
  kalman_signal_to_noise : float;
  kalman_warmup : int;
  (* cointegration *)
  coint_retest_bars : int;
  coint_min_bars : int;
  adf_p_lags : int;
  adf_variant : adf_variant;
  adf_signif : float;
  (* selection screen *)
  min_n : int;
  min_corr : float;
  max_adf_pvalue : float;
  min_half_life_bars : float;
  max_half_life_bars : float;
  max_beta_stdev : float;
  min_avg_volume : float;
  (* signal bands (z-score) *)
  entry_z : float;
  exit_z : float;
  stop_z : float;
  (* runtime *)
  min_publish_interval_ns : int64;
  max_active_pairs : int;
  max_price_staleness_ns : int64;
}

val default : t
