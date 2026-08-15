(** Quantifying how much of an optimized result is selection bias.

    This is the most useful module in the library and among the cheapest. An optimizer's job
    description is "find the parameters that scored best on this history", which is also a precise
    description of how to overfit. Search 500 configurations on one sample and the best Sharpe you
    find is drawn from the {i maximum} of 500 draws, not from the distribution of any single one —
    it is high because you looked 500 times.

    Everything here comes from Bailey & López de Prado. The p-values inherit the coarse-CDF caveat
    from [Advanced_models.Distribution]; two significant figures, no more. *)

module Normal = Algostream_advanced_models.Distribution.Normal

(** Expected maximum Sharpe from [n_trials] independent trials whose true Sharpe is zero and whose
    trial-to-trial standard deviation is [trial_sharpe_stdev].

    The number to compare an optimization result against. If your best-of-500 Sharpe is 1.4 and this
    says 1.3, you have found noise. *)
val expected_max_sharpe : n_trials:int -> trial_sharpe_stdev:float -> float

(** Deflated Sharpe ratio: the probability that the observed Sharpe exceeds what the best of
    [n_trials] would produce by chance, correcting for non-normality via [skewness] and
    [excess_kurtosis].

    Read it as a p-value in reverse — 0.95 means only a 5% chance this is selection bias. Below
    ~0.90 the result should not be traded. *)
val deflated_sharpe_ratio :
  observed_sharpe:float ->
  n_trials:int ->
  trial_sharpe_stdev:float ->
  skewness:float ->
  excess_kurtosis:float ->
  n_obs:int ->
  float

(** Probability of backtest overfitting (CSCV). Given, across many train/test splits, the in-sample
    rank of the configuration that won in-sample and its corresponding out-of-sample rank, this is
    the fraction of splits where the in-sample winner landed below the out-of-sample median.

    A PBO above 0.5 means the selection procedure is {i worse than picking at random} — the thing it
    selects for does not survive out of sample. Both arrays must be the same length. *)
val probability_of_backtest_overfitting : is_ranks:float array -> oos_ranks:float array -> float

(** Years of data needed before [target_sharpe] is distinguishable from the best of [n_trials]
    random strategies. Usually a sobering number, which is the point: it says up front whether the
    sample can support the search you are about to run. *)
val minimum_backtest_length : target_sharpe:float -> n_trials:int -> float

(** Standard error of a Sharpe estimate from [n_obs] observations, adjusted for skew and kurtosis
    (Lo 2002). Non-normal returns make a Sharpe less certain than the naive [1/sqrt n] suggests. *)
val sharpe_standard_error :
  sharpe:float -> skewness:float -> excess_kurtosis:float -> n_obs:int -> float

(** Haircut a Sharpe for multiple testing: the value that, after [n_trials] searches, carries the
    same evidential weight as the raw figure would from a single test. *)
val haircut_sharpe : observed_sharpe:float -> n_trials:int -> trial_sharpe_stdev:float -> float
