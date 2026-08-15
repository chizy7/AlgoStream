(** Immutable per-update snapshot published by {!Monitor}. Allocated fresh on each update;
    cross-Domain reads via [Atomic.get] on [Monitor.snapshot_atomic]. *)

type t = {
  ts_ns : int64;
  portfolio_value : float;
  var_pct : float;
  var_dollars : float;
  expected_shortfall_pct : float;
  expected_shortfall_dollars : float;
  current_drawdown : float;
  max_drawdown : float;
  peak_equity : float;
  time_under_water_ns : int64;
  gross_exposure : float;
  net_exposure : float;
  leverage_ratio : float;
  largest_position_pct : float;
  n_positions : int;
  correlation_status : Correlation_breakdown.status;
  circuit_breaker_state : Circuit_breaker.state;
  breaches : Risk_limits.breach list;
  ready : bool;
}

val empty : t

val to_string : t -> string
