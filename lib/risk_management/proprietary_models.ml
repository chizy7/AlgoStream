type risk_level =
  | Low
  | Moderate
  | High
  | Critical

type vol_regime =
  | Calm
  | Normal
  | Elevated
  | Stressed

type score = {
  composite : float;
  level : risk_level;
  var_component : float;
  drawdown_component : float;
  leverage_component : float;
  correlation_component : float;
  circuit_component : float;
  vol_regime : vol_regime;
  vol_ratio : float;
}

type weights = {
  var : float;
  drawdown : float;
  leverage : float;
  correlation : float;
  circuit : float;
}

let default_weights =
  { var = 0.30; drawdown = 0.25; leverage = 0.15; correlation = 0.15; circuit = 0.15 }


let normalize_clamped value limit = if limit <= 0.0 then 0.0 else min 1.0 (max 0.0 (value /. limit))

let correlation_severity = function
  | Correlation_breakdown.Stable -> 0.0
  | Correlation_breakdown.Weakening _ -> 0.33
  | Correlation_breakdown.Broken_down _ -> 0.67
  | Correlation_breakdown.Sign_flipped _ -> 1.0


let circuit_severity = function
  | Circuit_breaker.Active -> 0.0
  | Circuit_breaker.Recovering _ -> 0.5
  | Circuit_breaker.Tripped _ -> 1.0


let classify_vol_regime ~realized_vol ~baseline_vol =
  if baseline_vol <= 1e-12 then Normal
  else
    let r = realized_vol /. baseline_vol in
      if r < 0.5 then Calm else if r < 1.5 then Normal else if r < 3.0 then Elevated else Stressed


let classify_risk_level ~score =
  if score < 0.25 then Low
  else if score < 0.50 then Moderate
  else if score < 0.75 then High
  else Critical


let compute_score ?(weights = default_weights) ~var_pct ~max_var_pct ~current_drawdown ~max_drawdown
  ~leverage ~max_leverage ~correlation_status ~circuit_state ~realized_vol ~baseline_vol () =
  let var_c = normalize_clamped var_pct max_var_pct in
  let dd_c = normalize_clamped current_drawdown max_drawdown in
  let lev_c = normalize_clamped leverage max_leverage in
  let corr_c = correlation_severity correlation_status in
  let cb_c = circuit_severity circuit_state in
  let total_w =
    weights.var +. weights.drawdown +. weights.leverage +. weights.correlation +. weights.circuit
  in
  let w_sum = if total_w > 0.0 then total_w else 1.0 in
  let composite =
    ((weights.var *. var_c) +. (weights.drawdown *. dd_c) +. (weights.leverage *. lev_c)
   +. (weights.correlation *. corr_c) +. (weights.circuit *. cb_c))
    /. w_sum in
  let vol_regime = classify_vol_regime ~realized_vol ~baseline_vol in
  let vol_ratio = if baseline_vol > 1e-12 then realized_vol /. baseline_vol else 0.0 in
    {
      composite;
      level = classify_risk_level ~score:composite;
      var_component = var_c;
      drawdown_component = dd_c;
      leverage_component = lev_c;
      correlation_component = corr_c;
      circuit_component = cb_c;
      vol_regime;
      vol_ratio;
    }


let from_snapshot ~(snapshot : Risk_snapshot.t) ~(limits : Risk_limits.t) ~realized_vol
  ~baseline_vol ?weights () =
  compute_score ?weights ~var_pct:snapshot.var_pct ~max_var_pct:limits.max_var_pct
    ~current_drawdown:snapshot.current_drawdown ~max_drawdown:limits.max_drawdown
    ~leverage:snapshot.leverage_ratio ~max_leverage:limits.max_leverage
    ~correlation_status:snapshot.correlation_status ~circuit_state:snapshot.circuit_breaker_state
    ~realized_vol ~baseline_vol ()


let risk_level_to_string = function
  | Low -> "Low"
  | Moderate -> "Moderate"
  | High -> "High"
  | Critical -> "Critical"


let vol_regime_to_string = function
  | Calm -> "Calm"
  | Normal -> "Normal"
  | Elevated -> "Elevated"
  | Stressed -> "Stressed"


let score_to_string s =
  Printf.sprintf
    "[risk_score] %s (%.3f) | vol=%s (×%.2f) | var=%.2f dd=%.2f lev=%.2f corr=%.2f cb=%.2f"
    (risk_level_to_string s.level) s.composite
    (vol_regime_to_string s.vol_regime)
    s.vol_ratio s.var_component s.drawdown_component s.leverage_component s.correlation_component
    s.circuit_component
