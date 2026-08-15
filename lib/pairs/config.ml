type adf_variant =
  | No_constant
  | With_constant
  | With_trend

type beta_mode =
  | Static of float
  | Rolling_ols
  | Kalman_smoothed

type t = {
  corr_window : int;
  spread_window : int;
  beta_window : int;
  recompute_every : int;
  beta_mode : beta_mode;
  kalman_signal_to_noise : float;
  kalman_warmup : int;
  coint_retest_bars : int;
  coint_min_bars : int;
  adf_p_lags : int;
  adf_variant : adf_variant;
  adf_signif : float;
  min_n : int;
  min_corr : float;
  max_adf_pvalue : float;
  min_half_life_bars : float;
  max_half_life_bars : float;
  max_beta_stdev : float;
  min_avg_volume : float;
  entry_z : float;
  exit_z : float;
  stop_z : float;
  min_publish_interval_ns : int64;
  max_active_pairs : int;
  max_price_staleness_ns : int64;
}

let default =
  let window = 256 in
    {
      corr_window = window;
      spread_window = window;
      beta_window = window;
      recompute_every = max 8 (window / 16);
      beta_mode = Rolling_ols;
      kalman_signal_to_noise = 0.01;
      kalman_warmup = 64;
      coint_retest_bars = 64;
      coint_min_bars = 64;
      adf_p_lags = 1;
      adf_variant = With_constant;
      adf_signif = 0.05;
      min_n = 64;
      min_corr = 0.5;
      max_adf_pvalue = 0.05;
      min_half_life_bars = 1.0;
      max_half_life_bars = 100.0;
      max_beta_stdev = 0.5;
      min_avg_volume = 0.0;
      entry_z = 2.0;
      exit_z = 0.5;
      stop_z = 4.0;
      min_publish_interval_ns = 1_000_000L;
      max_active_pairs = 2048;
      max_price_staleness_ns = 5_000_000_000L;
    }
