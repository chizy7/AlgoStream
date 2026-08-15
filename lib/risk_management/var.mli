(** Value-at-Risk and Expected Shortfall with four computation methods.

    All methods produce the same [result] record so callers can switch between methods without
    changing call-site shape. [method_used] records which method actually ran for audit logging.
    Coarse-precision caveat carries over from [Advanced_models.Special] — claim no more than two
    significant figures in extreme tails. *)

type method_ =
  | Historical
    (** Empirical quantile + tail mean. Wraps
        {!Algostream_domain_portfolio.Portfolio.Risk_metrics.calculate_var} /
        [calculate_expected_shortfall]. Robust to non-normality but slow to react to regime changes
        (equally weighted history). *)
  | Parametric_normal
    (** Gaussian: [VaR = -(mu + sigma * Phi^{-1}(1-alpha))]. Use when returns are approximately
        normal. *)
  | Cornish_fisher
    (** Parametric with skewness/excess-kurtosis adjustment via Cornish-Fisher expansion.
        Recommended n ≥ 100; degenerate sample stats fall back to Parametric_normal. *)
  | Garch_forecast of Algostream_advanced_models.Garch11.t
    (** Parametric with forward-looking sigma from a fitted GARCH(1,1). Captures volatility
        clustering that historical sim averages out. *)

type result = {
  var_pct : float;
  var_dollars : float;
  expected_shortfall_pct : float;
  expected_shortfall_dollars : float;
  horizon_days : int;
  confidence : float;
  method_used : string;
}

val compute :
  method_:method_ ->
  returns:float array ->
  portfolio_value:float ->
  confidence:float ->
  horizon_days:int ->
  result

val report_to_string : result -> string
