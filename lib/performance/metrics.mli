(** Risk-adjusted performance metrics — the canonical implementations.

    {b Consolidation notice.} The tree carries {b four} max-drawdown implementations and {b three}
    Sharpe implementations, using three different formulas — two of them under the same field name:

    - [Portfolio.Risk_metrics.calculate_risk_metrics] sets [sharpe_ratio = mean_return / volatility]
    - [Portfolio.Portfolio_analytics.calculate_performance_summary] sets
      [sharpe_ratio = total_return / volatility]
    - [Math_utils.FinancialMath.sharpe_ratio] computes [(mean - rf) / stdev] over an array
    - [Pair.Pair_analytics] computes [average_trade_pnl / stdev_of_trade_pnl] — a per-trade figure,
      not a return-based one at all

    The last of those was found by [make metrics-dup-lint] on its first run, which is a fair
    illustration of why the lint exists. None of the four is annualized and only one subtracts a
    risk-free rate, so none is a Sharpe ratio in the conventional sense. Those functions are left in
    place — [Risk_metrics] is load-bearing for [Risk_management.Var.Historical] — but are marked
    superseded in their own doc comments. This module is where new code should look, and the
    [make metrics-dup-lint] target exists to stop a fourth implementation appearing.

    {b Conventions}, stated because this is exactly where implementations silently disagree:

    - Volatility is the {b sample} standard deviation ([n-1] denominator).
    - Downside deviation uses the {b full-sample} [n] denominator; observations above the MAR
      contribute zero rather than being dropped. See [Returns.downside_deviation].
    - Annualization multiplies the mean by [periods_per_year] and the standard deviation by
      [sqrt periods_per_year], via {!Returns.periods_per_year}. This assumes serially independent
      returns; for a strongly autocorrelated series the annualized volatility is understated, and no
      Newey-West correction is applied.
    - Every ratio returns [0.0], never [nan] or [infinity], when its denominator is zero. Which case
      produced the zero is recoverable from the component fields.
    - VaR and CVaR delegate to [Risk_management.Var.compute ~method_:Historical] rather than being
      recomputed here. *)

type t = {
  n_periods : int;
  periods_per_year : float;
  total_return : float;  (** fractional over the whole sample, not annualized *)
  cagr : float;  (** geometric annual growth rate *)
  ann_return : float;  (** arithmetic mean × periods_per_year *)
  ann_volatility : float;  (** sample stddev × sqrt periods_per_year *)
  ann_downside_deviation : float;
  sharpe : float;  (** [(ann_return - risk_free) / ann_volatility] *)
  sortino : float;  (** [(ann_return - mar) / ann_downside_deviation] *)
  calmar : float;  (** [cagr / |max_drawdown|] *)
  omega : float;  (** [Σ gains above MAR / Σ losses below MAR] *)
  ulcer_index : float;
  martin_ratio : float;  (** [(ann_return - risk_free) / ulcer_index] *)
  tail_ratio : float;  (** [|p95| / |p5|] of the return distribution *)
  max_drawdown : float;  (** fractional, positive *)
  max_drawdown_duration_ns : int64;
  skewness : float;
  excess_kurtosis : float;
  var_95 : float;  (** positive = loss, per period *)
  cvar_95 : float;
  var_99 : float;
  cvar_99 : float;
  best_period : float;
  worst_period : float;
  hit_rate : float;  (** fraction of periods with a positive return *)
  win_loss_ratio : float;  (** mean gain / |mean loss| *)
  time_in_market : float;  (** fraction of periods with a non-zero return *)
}

val empty : t

(** Compute from a return series. [periods_per_year] comes from {!Returns.periods_per_year}.
    [risk_free_rate_ann] and [mar_ann] are annual rates, converted internally to per-period.

    Drawdown fields are derived from the equity curve implied by compounding [returns]; pass [~nav]
    to {!of_nav} instead when the true NAV curve is available, which gives exact drawdown timings.
*)
val of_returns :
  returns:float array ->
  periods_per_year:float ->
  ?risk_free_rate_ann:float ->
  ?mar_ann:float ->
  unit ->
  t

(** Compute from a NAV curve. Preferred over {!of_returns}: the sampling interval is inferred from
    the timestamps, and drawdown durations are measured in real event time rather than in periods.
*)
val of_nav :
  nav:(int64 * float) array ->
  ?kind:Returns.kind ->
  ?days_per_year:float ->
  ?hours_per_day:float ->
  ?risk_free_rate_ann:float ->
  ?mar_ann:float ->
  unit ->
  t

(** Flatten to name/value pairs — the vector a Monte Carlo worker returns instead of a whole equity
    curve. Field order is stable across calls. *)
val to_assoc : t -> (string * float) array

val to_string : t -> string
