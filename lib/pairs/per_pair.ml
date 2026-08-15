module Bar = Algostream_time_series.Bar
module Rolling = Algostream_analytics.Rolling

type t = {
  pair : Pair_id.t;
  config : Config.t;
  hedge : Hedge_ratio.t;
  spread : Spread.t;
  corr : Correlation.t;
  reversion : Mean_reversion.t;
  vol_mean : Rolling.Rolling_mean.t;
  y_bar_buf : float array;
  x_bar_buf : float array;
  buf_cap : int;
  mutable buf_pos : int;
  mutable buf_n : int;
  mutable bars_since_retest : int;
  mutable last_adf : Adf.result option;
  mutable last_eg : Cointegration.Engle_granger.result option;
  mutable last_half_life : float;
  mutable last_event_ts_ns : int64;
  mutable last_publish_ts_ns : int64;
  mutable last_bar_close_ts : int64;
  mutable last_price_y : float;
  mutable last_price_x : float;
  mutable last_signal : Mean_reversion.signal;
  mutable n_ticks_proc : int;
  mutable n_bars_proc : int;
  mutable out_of_order : int;
  pub : Snapshot.t Atomic.t;
}

let create ~pair ~(config : Config.t) =
  let cap = max 64 (config.coint_min_bars * 4) in
    {
      pair;
      config;
      hedge = Hedge_ratio.create config;
      spread = Spread.create ~window:config.spread_window ~recompute_every:config.recompute_every;
      corr = Correlation.create ~window:config.corr_window ~recompute_every:config.recompute_every;
      reversion =
        Mean_reversion.create ~entry_z:config.entry_z ~exit_z:config.exit_z ~stop_z:config.stop_z;
      vol_mean = Rolling.Rolling_mean.create ~window:config.beta_window;
      y_bar_buf = Array.make cap 0.0;
      x_bar_buf = Array.make cap 0.0;
      buf_cap = cap;
      buf_pos = 0;
      buf_n = 0;
      bars_since_retest = 0;
      last_adf = None;
      last_eg = None;
      last_half_life = Float.nan;
      last_event_ts_ns = 0L;
      last_publish_ts_ns = 0L;
      last_bar_close_ts = 0L;
      last_price_y = 0.0;
      last_price_x = 0.0;
      last_signal = Mean_reversion.Hold;
      n_ticks_proc = 0;
      n_bars_proc = 0;
      out_of_order = 0;
      pub = Atomic.make (Snapshot.empty ~pair);
    }


let pair t = t.pair

let snapshot t = Atomic.get t.pub

let snapshot_atomic t = t.pub

let last_event_ts_ns t = t.last_event_ts_ns

let out_of_order_count t = t.out_of_order

let n_ticks_processed t = t.n_ticks_proc

let n_bars_processed t = t.n_bars_proc

let publish_snapshot t =
  let adf_t, adf_p = match t.last_adf with Some r -> (r.t_stat, r.p_value) | None -> (0.0, 1.0) in
  let coint = match t.last_eg with Some eg -> eg.cointegrated | None -> false in
  let snap : Snapshot.t =
    {
      pair = t.pair;
      last_event_ts_ns = t.last_event_ts_ns;
      n_ticks = t.n_ticks_proc;
      n_bars = t.buf_n;
      last_price_y = t.last_price_y;
      last_price_x = t.last_price_x;
      beta = Hedge_ratio.beta t.hedge;
      beta_stdev = Hedge_ratio.beta_stdev t.hedge;
      intercept = Hedge_ratio.intercept t.hedge;
      spread = Spread.current t.spread;
      spread_mean = Spread.mean t.spread;
      spread_std = Spread.std t.spread;
      z_score = Spread.z t.spread;
      corr = Correlation.value t.corr;
      adf_t_stat = adf_t;
      adf_p_value = adf_p;
      cointegrated = coint;
      half_life_bars = t.last_half_life;
      avg_volume = Rolling.Rolling_mean.value t.vol_mean;
      signal = t.last_signal;
      ready = Hedge_ratio.ready t.hedge && Spread.n t.spread > 4;
    } in
    Atomic.set t.pub snap


let on_tick t ~y_price ~x_price ~ts_ns =
  if Int64.compare ts_ns t.last_event_ts_ns < 0 then t.out_of_order <- t.out_of_order + 1
  else (
    t.last_event_ts_ns <- ts_ns ;
    t.last_price_y <- y_price ;
    t.last_price_x <- x_price ;
    t.n_ticks_proc <- t.n_ticks_proc + 1 ;
    let beta, intercept = Hedge_ratio.update t.hedge ~x:x_price ~y:y_price in
      ignore (Correlation.update t.corr ~y:y_price ~x:x_price : float) ;
      Spread.update t.spread ~y:y_price ~x:x_price ~beta ~intercept ~ts_ns ;
      let z = Spread.z t.spread in
      let signal = Mean_reversion.update t.reversion ~z in
        t.last_signal <- signal ;
        let dt = Int64.sub ts_ns t.last_publish_ts_ns in
        let first = Int64.equal t.last_publish_ts_ns 0L in
          if first || Int64.compare dt t.config.min_publish_interval_ns >= 0 then (
            publish_snapshot t ;
            t.last_publish_ts_ns <- ts_ns))


let materialize_buf ~pos ~n ~cap arr =
  if n < cap then Array.sub arr 0 n
  else
    let out = Array.make n 0.0 in
    let first = cap - pos in
      Array.blit arr pos out 0 first ;
      Array.blit arr 0 out first pos ;
      out


let run_retest t =
  let y_arr = materialize_buf ~pos:t.buf_pos ~n:t.buf_n ~cap:t.buf_cap t.y_bar_buf in
  let x_arr = materialize_buf ~pos:t.buf_pos ~n:t.buf_n ~cap:t.buf_cap t.x_bar_buf in
    match
      Cointegration.Engle_granger.test ~y:y_arr ~x:x_arr ~signif:t.config.adf_signif
        ~adf_variant:Adf.No_constant ~adf_lag:t.config.adf_p_lags ()
    with
    | Error _ -> ()
    | Ok eg ->
      t.last_eg <- Some eg ;
      t.last_adf <- Some eg.residual_adf ;
      (match Mean_reversion.half_life ~residuals:eg.residuals with
      | Ok hl -> t.last_half_life <- hl
      | Error _ -> t.last_half_life <- Float.nan)


let on_bar t ~y_bar ~x_bar =
  if Int64.compare y_bar.Bar.close_ts t.last_bar_close_ts <= 0 then ()
  else if not (Int64.equal y_bar.Bar.open_ts x_bar.Bar.open_ts) then ()
  else (
    t.last_bar_close_ts <- y_bar.Bar.close_ts ;
    t.n_bars_proc <- t.n_bars_proc + 1 ;
    t.y_bar_buf.(t.buf_pos) <- y_bar.Bar.close ;
    t.x_bar_buf.(t.buf_pos) <- x_bar.Bar.close ;
    t.buf_pos <- (t.buf_pos + 1) mod t.buf_cap ;
    if t.buf_n < t.buf_cap then t.buf_n <- t.buf_n + 1 ;
    t.bars_since_retest <- t.bars_since_retest + 1 ;
    let vol = Float.min y_bar.Bar.volume x_bar.Bar.volume in
      ignore (Rolling.Rolling_mean.update t.vol_mean vol : float) ;
      if t.buf_n >= t.config.coint_min_bars && t.bars_since_retest >= t.config.coint_retest_bars
      then (
        run_retest t ;
        t.bars_since_retest <- 0))
