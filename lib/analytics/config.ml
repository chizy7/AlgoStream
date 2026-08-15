type t = {
  rolling_window : int;
  ewma_period : int;
  ewma_vol_period : int;
  recompute_every : int;
  z_score_threshold : float;
  hampel_threshold : float;
  outlier_warmup : int;
  kalman_signal_to_noise : float;
  kalman_warmup : int;
  regime_calm_to_trending_dwell_ns : int64;
  regime_calm_to_volatile_dwell_ns : int64;
  regime_to_crisis_dwell_ns : int64;
  regime_crisis_to_other_dwell_ns : int64;
  regime_volatile_to_calm_dwell_ns : int64;
  regime_trending_to_calm_dwell_ns : int64;
  regime_calm_to_trending_min_ticks : int;
  regime_calm_to_volatile_min_ticks : int;
  regime_to_crisis_min_ticks : int;
  regime_crisis_to_other_min_ticks : int;
  regime_volatile_to_calm_min_ticks : int;
  regime_trending_to_calm_min_ticks : int;
  regime_volatile_band : float;
  regime_crisis_drawdown : float;
  min_publish_interval_ns : int64;
  max_active_symbols : int;
}

let default =
  let window = 256 in
    {
      rolling_window = window;
      ewma_period = 60;
      ewma_vol_period = 120;
      recompute_every = max 8 (window / 16);
      z_score_threshold = 5.0;
      hampel_threshold = 4.5;
      outlier_warmup = 30;
      kalman_signal_to_noise = 0.01;
      kalman_warmup = 1024;
      regime_calm_to_trending_dwell_ns = 5_000_000_000L;
      regime_calm_to_volatile_dwell_ns = 2_000_000_000L;
      regime_to_crisis_dwell_ns = 1_000_000_000L;
      regime_crisis_to_other_dwell_ns = 30_000_000_000L;
      regime_volatile_to_calm_dwell_ns = 15_000_000_000L;
      regime_trending_to_calm_dwell_ns = 10_000_000_000L;
      regime_calm_to_trending_min_ticks = 50;
      regime_calm_to_volatile_min_ticks = 20;
      regime_to_crisis_min_ticks = 10;
      regime_crisis_to_other_min_ticks = 200;
      regime_volatile_to_calm_min_ticks = 100;
      regime_trending_to_calm_min_ticks = 80;
      regime_volatile_band = 1.8;
      regime_crisis_drawdown = 0.05;
      min_publish_interval_ns = 10_000_000L;
      max_active_symbols = 256;
    }
