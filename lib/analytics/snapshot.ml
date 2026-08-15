type t = {
  symbol : string;
  last_event_ts_ns : int64;
  n_ticks : int;
  last_price : float;
  denoised_price : float;
  realized_vol : float;
  ewma_vol : float;
  rolling_mean_price : float;
  rolling_std_price : float;
  drawdown_from_peak : float;
  regime : Regime.t;
  regime_dwell_ns : int64;
  rejected_count : int;
  ready : bool;
}

let empty ~symbol =
  {
    symbol;
    last_event_ts_ns = 0L;
    n_ticks = 0;
    last_price = 0.0;
    denoised_price = 0.0;
    realized_vol = 0.0;
    ewma_vol = 0.0;
    rolling_mean_price = 0.0;
    rolling_std_price = 0.0;
    drawdown_from_peak = 0.0;
    regime = Regime.Calm;
    regime_dwell_ns = 0L;
    rejected_count = 0;
    ready = false;
  }


let to_string t =
  Printf.sprintf "[%s] ts=%Ld n=%d price=%g denoised=%g rvol=%g ewmavol=%g dd=%g regime=%s ready=%b"
    t.symbol t.last_event_ts_ns t.n_ticks t.last_price t.denoised_price t.realized_vol t.ewma_vol
    t.drawdown_from_peak (Regime.to_string t.regime) t.ready
