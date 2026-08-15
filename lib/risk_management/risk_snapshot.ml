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

let empty =
  {
    ts_ns = 0L;
    portfolio_value = 0.0;
    var_pct = 0.0;
    var_dollars = 0.0;
    expected_shortfall_pct = 0.0;
    expected_shortfall_dollars = 0.0;
    current_drawdown = 0.0;
    max_drawdown = 0.0;
    peak_equity = 0.0;
    time_under_water_ns = 0L;
    gross_exposure = 0.0;
    net_exposure = 0.0;
    leverage_ratio = 0.0;
    largest_position_pct = 0.0;
    n_positions = 0;
    correlation_status = Correlation_breakdown.Stable;
    circuit_breaker_state = Circuit_breaker.Active;
    breaches = [];
    ready = false;
  }


let to_string t =
  Printf.sprintf
    "[risk] ts=%Ld nav=%g var=%g(%g$) es=%g(%g$) dd=%g(max=%g) lev=%g n=%d corr=%s cb=%s \
     breaches=%d ready=%b"
    t.ts_ns t.portfolio_value t.var_pct t.var_dollars t.expected_shortfall_pct
    t.expected_shortfall_dollars t.current_drawdown t.max_drawdown t.leverage_ratio t.n_positions
    (Correlation_breakdown.status_to_string t.correlation_status)
    (Circuit_breaker.state_to_string t.circuit_breaker_state)
    (List.length t.breaches) t.ready
