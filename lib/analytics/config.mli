(** Per-symbol analytics configuration.

    Defaults are sensible starting points for crypto majors at second-level granularity. Tune via
    [Config.create] for your particular feed. *)

type t = {
  rolling_window : int; (* number of ticks for rolling stats; default 256 *)
  ewma_period : int; (* period -> alpha = 2/(period+1); default 60 *)
  ewma_vol_period : int; (* period for EWMA volatility; default 120 *)
  recompute_every : int;
    (* how often Rolling_var/cov/corr fully recomputes; default = max 8 (window/16) *)
  z_score_threshold : float; (* outlier rejection band; default 5.0 *)
  hampel_threshold : float; (* MAD-multiplier; default 4.5 *)
  outlier_warmup : int; (* number of ticks before outlier filters become active; default 30 *)
  kalman_signal_to_noise : float; (* Q/R; default 0.01 (smoothing dominates) *)
  kalman_warmup : int; (* number of ticks for Q/R bootstrap; default 1024 *)
  regime_calm_to_trending_dwell_ns : int64; (* default 5e9 *)
  regime_calm_to_volatile_dwell_ns : int64; (* default 2e9 *)
  regime_to_crisis_dwell_ns : int64; (* default 1e9 *)
  regime_crisis_to_other_dwell_ns : int64; (* default 30e9 *)
  regime_volatile_to_calm_dwell_ns : int64; (* default 15e9 *)
  regime_trending_to_calm_dwell_ns : int64; (* default 10e9 *)
  regime_calm_to_trending_min_ticks : int;
  regime_calm_to_volatile_min_ticks : int;
  regime_to_crisis_min_ticks : int;
  regime_crisis_to_other_min_ticks : int;
  regime_volatile_to_calm_min_ticks : int;
  regime_trending_to_calm_min_ticks : int;
  regime_volatile_band : float; (* ewma_vol / median_lookback ratio threshold for Volatile *)
  regime_crisis_drawdown : float; (* drawdown fraction for Crisis trigger; default 0.05 *)
  min_publish_interval_ns : int64;
    (* min event-time gap between Atomic.set snapshot publishes; default 1e7 (10 ms) *)
  max_active_symbols : int; (* LRU cap on Per_symbol.t map; default 256 *)
}

val default : t
