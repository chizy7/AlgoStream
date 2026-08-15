(** Proprietary composite risk score.

    Bundles the per-dimension risk signals produced by [Monitor.update] — GARCH-forecast VaR vs
    limit, drawdown vs limit, leverage vs limit, correlation breakdown severity, circuit-breaker
    state, and a realized-vs-baseline volatility regime — into a single 0..1 [composite] score with
    a [risk_level] tier ({!Low} / {!Moderate} / {!High} / {!Critical}) and an independent
    volatility-regime classification ({!Calm} / {!Normal} / {!Elevated} / {!Stressed}).

    Default weights bias toward forward-looking VaR (0.30) and drawdown (0.25) over the lagging
    signals. Strategies override [~weights] when they have a different risk philosophy. *)

(** Tier classification of the composite score:
    - [Low] — score < 0.25
    - [Moderate] — 0.25 ≤ score < 0.50
    - [High] — 0.50 ≤ score < 0.75
    - [Critical] — score ≥ 0.75 *)
type risk_level =
  | Low
  | Moderate
  | High
  | Critical

(** Vol-regime classification based on realized / baseline volatility ratio:
    - [Calm] — ratio < 0.5
    - [Normal] — 0.5 ≤ ratio < 1.5
    - [Elevated] — 1.5 ≤ ratio < 3.0
    - [Stressed] — ratio ≥ 3.0 *)
type vol_regime =
  | Calm
  | Normal
  | Elevated
  | Stressed

(** Each component is in [0, 1] — 0 means "well within limit", 1 means "at or beyond limit".
    [composite] is the weighted average. *)
type score = {
  composite : float;
  level : risk_level;
  var_component : float;
  drawdown_component : float;
  leverage_component : float;
  correlation_component : float;
  circuit_component : float;
  vol_regime : vol_regime;
  vol_ratio : float;  (** realized_vol / baseline_vol *)
}

type weights = {
  var : float;
  drawdown : float;
  leverage : float;
  correlation : float;
  circuit : float;
}

(** Default weights: var=0.30, drawdown=0.25, leverage=0.15, correlation=0.15, circuit=0.15. Sum
    normalized to 1.0 during composition; any positive weights work. *)
val default_weights : weights

val classify_vol_regime : realized_vol:float -> baseline_vol:float -> vol_regime

val classify_risk_level : score:float -> risk_level

(** Pure-function composition. All inputs explicit so the function is trivially testable. *)
val compute_score :
  ?weights:weights ->
  var_pct:float ->
  max_var_pct:float ->
  current_drawdown:float ->
  max_drawdown:float ->
  leverage:float ->
  max_leverage:float ->
  correlation_status:Correlation_breakdown.status ->
  circuit_state:Circuit_breaker.state ->
  realized_vol:float ->
  baseline_vol:float ->
  unit ->
  score

(** Convenience: derive the score directly from a published {!Risk_snapshot.t} + the [Risk_limits.t]
    config + the [Monitor]'s last realized + baseline volatility (via [Monitor.realized_vol] /
    [Monitor.baseline_vol]). *)
val from_snapshot :
  snapshot:Risk_snapshot.t ->
  limits:Risk_limits.t ->
  realized_vol:float ->
  baseline_vol:float ->
  ?weights:weights ->
  unit ->
  score

val risk_level_to_string : risk_level -> string

val vol_regime_to_string : vol_regime -> string

val score_to_string : score -> string
