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

let empty ~pair =
  {
    pair;
    last_event_ts_ns = 0L;
    n_ticks = 0;
    n_bars = 0;
    last_price_y = 0.0;
    last_price_x = 0.0;
    beta = 0.0;
    beta_stdev = 0.0;
    intercept = 0.0;
    spread = 0.0;
    spread_mean = 0.0;
    spread_std = 0.0;
    z_score = 0.0;
    corr = 0.0;
    adf_t_stat = 0.0;
    adf_p_value = 1.0;
    cointegrated = false;
    half_life_bars = Float.nan;
    avg_volume = 0.0;
    signal = Mean_reversion.Hold;
    ready = false;
  }


let to_string t =
  Printf.sprintf
    "[%s] ts=%Ld n=%d β=%g z=%.3g corr=%.3g adf_p=%.3g hl=%.2f coint=%b sig=%s ready=%b"
    (Pair_id.to_string t.pair) t.last_event_ts_ns t.n_ticks t.beta t.z_score t.corr t.adf_p_value
    t.half_life_bars t.cointegrated
    (Mean_reversion.signal_to_string t.signal)
    t.ready
