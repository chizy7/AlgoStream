module Stats = Algostream_common_utils.Math_utils.Statistics

type t = {
  symbol : string;
  config : Config.t;
  (* outlier pipeline *)
  z_score : Outlier.Z_score.t;
  hampel : Outlier.Hampel.t; (* present but not in default pipeline; opt-in *)
  (* denoiser *)
  kalman : Filters.Kalman1d.t;
  ewma : Filters.Ewma.t;
  (* rolling stats *)
  rolling_mean : Rolling.Rolling_mean.t;
  rolling_var : Rolling.Rolling_var.t;
  (* volatility *)
  realized_vol : Volatility.Realized.t;
  ewma_vol : Volatility.Ewma.t;
  (* regime detector *)
  regime : Regime.detector;
  (* drawdown peak tracker *)
  mutable peak_price : float;
  (* return-run tracker for trending detection *)
  mutable last_log_return : float;
  mutable run_length : int;
  mutable run_sign : int;
  (* baseline median EWMA-vol for the regime detector's vol-band threshold *)
  vol_band_median : Stats.percentile_tracker;
  mutable cached_vol_band_median : float;
  (* counters *)
  mutable rejected_count : int;
  mutable out_of_order_count : int;
  mutable last_event_ts_ns : int64;
  mutable last_publish_ts_ns : int64;
  (* lock-free read snapshot *)
  pub : Snapshot.t Atomic.t;
}

let log_src = Logs.Src.create "algostream.analytics.per_symbol"

module Log = (val Logs.src_log log_src : Logs.LOG)

let symbol t = t.symbol

let last_event_ts_ns t = t.last_event_ts_ns

let rejected_count t = t.rejected_count

let out_of_order_count t = t.out_of_order_count

let snapshot t = Atomic.get t.pub

let snapshot_atomic t = t.pub

let create ~symbol ~config =
  {
    symbol;
    config;
    z_score =
      Outlier.Z_score.create ~threshold:config.Config.z_score_threshold
        ~warmup:config.outlier_warmup ~ewma_period:config.ewma_period;
    hampel =
      Outlier.Hampel.create ~threshold:config.hampel_threshold ~warmup:config.outlier_warmup
        ~window:64;
    kalman =
      Filters.Kalman1d.create ~signal_to_noise_ratio:config.kalman_signal_to_noise
        ~warmup:config.kalman_warmup;
    ewma = Filters.Ewma.create ~period:config.ewma_period;
    rolling_mean = Rolling.Rolling_mean.create ~window:config.rolling_window;
    rolling_var =
      Rolling.Rolling_var.create ~window:config.rolling_window
        ~recompute_every:config.recompute_every;
    realized_vol =
      Volatility.Realized.create ~window:config.rolling_window
        ~recompute_every:config.recompute_every;
    ewma_vol = Volatility.Ewma.create ~period:config.ewma_vol_period;
    regime = Regime.create config;
    peak_price = 0.0;
    last_log_return = 0.0;
    run_length = 0;
    run_sign = 0;
    vol_band_median = Stats.create_percentile_tracker 256;
    cached_vol_band_median = 0.0;
    rejected_count = 0;
    out_of_order_count = 0;
    last_event_ts_ns = 0L;
    last_publish_ts_ns = 0L;
    pub = Atomic.make (Snapshot.empty ~symbol);
  }


(* Default v1 outlier pipeline: Sanity (already pre-filtered at the bus shim, but cheap to repeat
   here as a defensive guardrail) + Z-score. Hampel is constructed but kept off the hot path because
   its O(window log window) median/MAD recompute every tick is the bench bottleneck; strategies that
   need extreme robustness can extend the pipeline themselves. *)
let pipeline t =
  [
    Outlier.wrap (module Outlier.Sanity) Outlier.sanity;
    Outlier.wrap (module Outlier.Z_score) t.z_score;
  ]


let _ = fun (t : t) -> t.hampel
(* Suppresses unused-field warning on [hampel] until we expose an extended pipeline ctor. *)

let publish_snapshot t =
  let snap : Snapshot.t =
    {
      symbol = t.symbol;
      last_event_ts_ns = t.last_event_ts_ns;
      n_ticks = Rolling.Rolling_mean.n t.rolling_mean;
      last_price = (match Filters.Kalman1d.value t.kalman with v -> v);
      denoised_price = Filters.Kalman1d.value t.kalman;
      realized_vol = Volatility.Realized.value t.realized_vol;
      ewma_vol = Volatility.Ewma.value t.ewma_vol;
      rolling_mean_price = Rolling.Rolling_mean.value t.rolling_mean;
      rolling_std_price = sqrt (Rolling.Rolling_var.value t.rolling_var);
      drawdown_from_peak =
        (let p = Filters.Kalman1d.value t.kalman in
           if t.peak_price > 0.0 then max 0.0 ((t.peak_price -. p) /. t.peak_price) else 0.0);
      regime = Regime.current t.regime;
      regime_dwell_ns = Regime.dwell_ns t.regime;
      rejected_count = t.rejected_count;
      ready =
        Filters.Ewma.ready t.ewma && Volatility.Ewma.ready t.ewma_vol
        && Filters.Kalman1d.ready t.kalman;
    } in
    Atomic.set t.pub snap


let on_tick t (ev : Tick_event.t) =
  (* out-of-order rejection *)
  if Int64.compare ev.timestamp_ns t.last_event_ts_ns < 0 then (
    t.out_of_order_count <- t.out_of_order_count + 1 ;
    Log.debug (fun m ->
      m "[%s] out-of-order tick ts=%Ld last=%Ld" t.symbol ev.timestamp_ns t.last_event_ts_ns))
  else (
    t.last_event_ts_ns <- ev.timestamp_ns ;
    let price = ev.price in
      (* Sanity has already been checked at the bus shim, but Z_score / Hampel may still reject. *)
      match Outlier.run (pipeline t) price with
      | Outlier.Reject _ -> t.rejected_count <- t.rejected_count + 1
      | Outlier.Pass ->
        let prev_price = Filters.Kalman1d.value t.kalman in
        let denoised = Filters.Kalman1d.update t.kalman price in
          ignore (Filters.Ewma.update t.ewma price : float) ;
          ignore (Rolling.Rolling_mean.update t.rolling_mean price : float) ;
          ignore (Rolling.Rolling_var.update t.rolling_var price : float) ;
          let _ = Volatility.Realized.update t.realized_vol ~price in
          let ewma_vol = Volatility.Ewma.update t.ewma_vol ~price in
          (* Reservoir sampling AND median recompute are O(N log N) — sample + recompute every 128
             ticks. Use the cached median between updates. *)
          let n_ticks = Rolling.Rolling_mean.n t.rolling_mean in
            if n_ticks mod 128 = 0 then (
              Stats.update_percentile_tracker t.vol_band_median ewma_vol ;
              t.cached_vol_band_median <- Stats.get_percentile t.vol_band_median 0.5) ;
            let vol_band_median = t.cached_vol_band_median in
              (* update peak / drawdown *)
              if denoised > t.peak_price then t.peak_price <- denoised ;
              let drawdown =
                if t.peak_price > 0.0 then max 0.0 ((t.peak_price -. denoised) /. t.peak_price)
                else 0.0 in
              (* update return-run *)
              let log_ret =
                if prev_price > 0.0 && price > 0.0 then log (price /. prev_price) else 0.0 in
              let sign = if log_ret > 1e-9 then 1 else if log_ret < -1e-9 then -1 else 0 in
                if sign = 0 || sign <> t.run_sign then (
                  t.run_sign <- sign ;
                  t.run_length <- (if sign = 0 then 0 else 1))
                else t.run_length <- t.run_length + 1 ;
                t.last_log_return <- log_ret ;
                let _ =
                  Regime.update t.regime ~ts_ns:ev.timestamp_ns ~ewma_vol ~vol_band_median
                    ~drawdown_from_peak:drawdown ~return_run_length:t.run_length
                    ~return_run_sign:t.run_sign in
                let dt = Int64.sub ev.timestamp_ns t.last_publish_ts_ns in
                let first_publish = Int64.equal t.last_publish_ts_ns 0L in
                  if first_publish || Int64.compare dt t.config.min_publish_interval_ns >= 0 then (
                    publish_snapshot t ;
                    t.last_publish_ts_ns <- ev.timestamp_ns))
