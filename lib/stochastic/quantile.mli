(** Exact sample quantiles and bootstrap confidence intervals.

    {b Do not use [Math_utils.Statistics.create_percentile_tracker] for any confidence interval.} It
    is reservoir-sampled (so approximate) {i and} seeded with [Random.State.make_self_init ()] (so
    not reproducible across runs). Both properties are disqualifying for a Monte Carlo result that
    is supposed to be replayable. Everything here sorts the full sample.

    Working in empirical quantiles rather than parametric CDFs is also what lets this module escape
    the "claim no more than two significant figures" caveat that applies to
    [Advanced_models.Distribution] — a percentile interval never inverts a CDF. {!bca} is the one
    exception; it uses [Distribution.Normal] and inherits the caveat. *)

(** Type-7 quantile (linear interpolation between order statistics) — the default in R and NumPy.
    [sorted] must already be ascending; [p] is clamped to [[0, 1]]. Raises [Invalid_argument] on an
    empty array. *)
val of_sorted : sorted:float array -> p:float -> float

(** {!of_sorted} on a sorted copy of the input. O(n log n) per call — sort once and reuse
    {!of_sorted} when taking several quantiles from the same sample. *)
val quantile : float array -> p:float -> float

val median : float array -> float

(** Percentile-method interval. [level = 0.95] returns the 2.5% and 97.5% points. *)
val percentile_interval : float array -> level:float -> float * float

(** Basic (reverse-percentile) interval: [(2θ̂ - q_{1-α/2}, 2θ̂ - q_{α/2})]. Corrects for bias in the
    opposite direction to the percentile method; the two disagreeing is a signal the bootstrap
    distribution is skewed and {!bca} is warranted. *)
val basic_interval : float array -> point_estimate:float -> level:float -> float * float

(** Bias-corrected and accelerated interval. [jackknife] holds the leave-one-out estimates of the
    statistic, from which the acceleration constant is computed. Preferred when the statistic's
    distribution is skewed — which Sharpe ratios and maximum drawdowns always are. Falls back to
    {!percentile_interval} when the sample is degenerate. *)
val bca :
  float array -> point_estimate:float -> jackknife:float array -> level:float -> float * float

(** Monte Carlo standard error of the [p]-quantile {i estimate}, by the standard order-statistic
    formula [sqrt(p(1-p)/n) / f(q_p)] with the density estimated from a finite difference of the
    empirical quantile function.

    Reporting this alongside an interval is the difference between an honest confidence interval and
    a decorative one: at [n = 10_000] and [p = 0.99] only ~100 observations sit in the tail, so the
    99% level is materially less certain than the 95% level, and the caller deserves to know by how
    much. *)
val mc_standard_error : float array -> p:float -> float

(** One-pass summary of a Monte Carlo metric distribution. *)
type summary = {
  n : int;
  mean : float;
  stddev : float;
  min : float;
  max : float;
  p01 : float;
  p05 : float;
  p25 : float;
  p50 : float;
  p75 : float;
  p95 : float;
  p99 : float;
  ci95_lo : float;
  ci95_hi : float;
  ci99_lo : float;
  ci99_hi : float;
  prob_negative : float;
  skewness : float;
  excess_kurtosis : float;
  mc_se_p05 : float;
  mc_se_p95 : float;
}

val summarize : float array -> summary

val summary_to_string : summary -> string
