(** Statistical hypothesis tests.

    Seven tests, one uniform result type. p-values are computed by [Distribution]'s coarse CDFs; the
    [Pairs.Mackinnon_cv] caveat applies — claim no more than two significant figures.

    All tests are two-tailed unless documented otherwise. *)

type result = {
  name : string;
  statistic : float;
  p_value : float;
  dof : float option;
}

val reject : result -> alpha:float -> bool

(** H₀: sample mean = [mu0]. *)
val one_sample_t : sample:float array -> mu0:float -> result

(** H₀: mean(sample_a) = mean(sample_b). Welch by default; pass [~equal_var:true] for the pooled
    variant. *)
val two_sample_t : sample_a:float array -> sample_b:float array -> ?equal_var:bool -> unit -> result

(** Pearson chi-squared goodness of fit. [observed] and [expected] must have equal length and
    matching totals. df = k − 1. *)
val chi_squared_gof : observed:float array -> expected:float array -> result

(** Kolmogorov-Smirnov one-sample: H₀: sample drawn from distribution with the given [cdf]. *)
val ks_one_sample : sample:float array -> cdf:(float -> float) -> result

(** Kolmogorov-Smirnov two-sample: H₀: the two samples come from the same distribution. *)
val ks_two_sample : sample_a:float array -> sample_b:float array -> result

(** Jarque-Bera normality test. H₀: sample is normal. df = 2 (skew + excess kurtosis). *)
val jarque_bera : sample:float array -> result

(** Ljung-Box: H₀: no autocorrelation up to lag [lags]. df = [lags]. *)
val ljung_box : residuals:float array -> lags:int -> result

(** Wald-Wolfowitz runs test for randomness around the sample mean. *)
val runs_test : sample:float array -> result
