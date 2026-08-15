(** Monte Carlo over a strategy.

    {2 Two modes, because "10,000 runs" and "path-dependent scenarios" cost differently}

    - {b Path-level} ({!run_paths}) resamples a {i return series} and recomputes metrics. Millions
      of paths per second. This is what makes the 10,000-run target routine, and it is the right
      tool for "is this equity curve distinguishable from luck".
    - {b Engine-level} ({!run}) generates a synthetic {i market} and replays the whole backtest
      engine over it. Roughly a second per run. It is the only mode that captures path-dependent
      effects — stops firing, position sizing responding to drawdown, impact moving the mark — and
      the only one where the fill model participates.

    Both ship. The guide publishes both numbers rather than quoting the cheap one and implying the
    expensive one.

    {2 Reproducibility}

    Run [i] draws from exactly two substreams of [root_seed]: index [2i] for data and [2i+1] for
    execution. Neither depends on [n_domains], on scheduling, or on how many runs preceded it.
    Therefore [run] with [n_domains = 1] and with [n_domains = 16] produce bit-identical summaries,
    which [test/montecarlo/test_engine.ml] asserts.

    {2 Memory}

    10,000 runs × a full equity curve is gigabytes, so {b metrics are computed inside the worker}
    and only a ~27-float vector crosses back. [keep_first_n_results] retains whole {!Result.t}
    values for the first few runs, for debugging. This is a hard constraint on the API, not an
    optimization. *)

module Rng = Algostream_rng.Rng
module Metrics = Algostream_performance.Metrics
module Quantile = Algostream_stochastic.Quantile
module Backtest_engine = Algostream_backtest.Engine
module Result = Algostream_backtest.Result

type config = {
  n_runs : int;
  root_seed : int64;
  n_domains : int;  (** [<= 1] runs inline; see {!Pool.recommended_domains} *)
  generator : Generator.t;
  n_steps : int;  (** path length per run *)
  backtest : Backtest_engine.config;
  keep_first_n_results : int;  (** default 3 *)
}

val default_config :
  n_runs:int ->
  root_seed:int64 ->
  generator:Generator.t ->
  backtest:Backtest_engine.config ->
  config

type summary = {
  n_runs : int;
  n_failed : int;
  root_seed : int64;
  generator : string;
  per_metric : (string * Quantile.summary) array;
    (** one distribution per {!Metrics} field, in [Metrics.to_assoc] order *)
  failures : (int * string) array;  (** run index and message, in index order *)
  retained : Result.t array;
}

(** Engine-level Monte Carlo: [n_runs] full backtests over synthetic markets. *)
val run :
  (module Algostream_strategy.Strategy.S with type params = 'p) ->
  params:'p ->
  config:config ->
  summary

(** Path-level Monte Carlo: resample a return series [n_runs] times and recompute metrics. No
    strategy, no fill model — you are asking about the
    {i distribution of the equity curve you already have}, not about how it would have been
    executed. *)
val run_paths :
  returns:float array ->
  n_runs:int ->
  root_seed:int64 ->
  n_domains:int ->
  periods_per_year:float ->
  ?block_len:int ->
  ?n_domains_hint:int ->
  unit ->
  summary

(** One side of a paired comparison.

    [backtest] overrides {!config.backtest} for this arm only. It exists because the interesting
    comparisons are not all parameter changes: risk limits, cost model, slippage and latency live in
    the {i backtest config}, so a params-only comparative cannot express "same strategy, same
    market, risk limits on versus off". *)
type 'p arm = {
  params : 'p;
  backtest : Backtest_engine.config option;  (** [None] uses the shared {!config.backtest} *)
}

(** An arm that changes only parameters. *)
val arm : 'p -> 'p arm

(** An arm that changes the backtest configuration. *)
val arm_with : 'p -> Backtest_engine.config -> 'p arm

type comparison = {
  n_runs : int;
  n_failed : int;
    (** Runs where either arm raised. Reported rather than dropped: a comparison computed from the
        subset that happened to survive is a biased sample, and silently returning it as though it
        were the whole batch is the failure mode worth guarding. *)
  failures : (int * string) array;
  per_metric : (string * Quantile.summary) array;
    (** Distribution of [B − A] per {!Metrics} field, in [Metrics.to_assoc] order. *)
}

(** Paired comparison under common random numbers: run [i] of A and run [i] of B share substream
    [2i], so the two see the same market and differ only in whatever the arms differ in. Reports the
    distribution of the {i difference}, which has far lower variance than differencing two
    independent batches — and is the statistically correct way to ask "is A better than B". *)
val run_comparative :
  (module Algostream_strategy.Strategy.S with type params = 'p) ->
  a:'p arm ->
  b:'p arm ->
  config:config ->
  comparison

(** Look up one metric's distribution by name. *)
val metric : summary -> string -> Quantile.summary option

val summary_to_string : summary -> string
