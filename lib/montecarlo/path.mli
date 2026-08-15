(** Synthetic price-path generators.

    Distinguish two things often worded as one. {i Bootstrap} (in [Stochastic.Resample]) reshuffles
    history and so can only produce futures made of past pieces. {i Path generation} draws from a
    fitted model and can produce futures history never contained — including the tail events that
    matter most for a drawdown distribution.

    {b The GARCH sampler is new work.} [Advanced_models.Garch11.forecast] returns a deterministic
    sequence of σ² forecasts; it does not simulate. {!garch} closes the loop: draw [ε_t ~ N(0,1)],
    set [r_t = σ_t · ε_t], then advance the recursion with [Garch11.update]. That is ~20 lines over
    the existing model and it is what reproduces volatility clustering — the property an iid
    bootstrap destroys and which dominates how bad the worst drawdown gets. *)

module Rng = Algostream_rng.Rng
module Garch11 = Algostream_advanced_models.Garch11
module Ornstein_uhlenbeck = Algostream_advanced_models.Ornstein_uhlenbeck

(** Geometric Brownian motion. [mu] and [sigma] are per-unit-time; [dt] is in the same units. *)
val gbm : rng:Rng.t -> s0:float -> mu:float -> sigma:float -> n:int -> dt:float -> float array

(** Ornstein-Uhlenbeck, delegating to [Ornstein_uhlenbeck.simulate_with] so both callers share one
    exact-Gaussian-transition implementation. *)
val ou :
  rng:Rng.t -> params:Ornstein_uhlenbeck.params -> r0:float -> n:int -> dt:float -> float array

(** GARCH(1,1) {i return} path. Returns [n] returns, not prices — compose with {!prices_of_returns}.
    Reproduces volatility clustering. *)
val garch_returns : rng:Rng.t -> model:Garch11.t -> n:int -> float array

(** GARCH(1,1) price path from [s0]. *)
val garch : rng:Rng.t -> model:Garch11.t -> s0:float -> n:int -> float array

(** Merton jump-diffusion: GBM plus Poisson-timed lognormal jumps. The cheapest honest way to put
    fat tails and gaps into a synthetic path. [lambda] is the expected jump count per unit time. *)
val merton_jump_diffusion :
  rng:Rng.t ->
  s0:float ->
  mu:float ->
  sigma:float ->
  lambda:float ->
  jump_mu:float ->
  jump_sigma:float ->
  n:int ->
  dt:float ->
  float array

(** Correlated multi-asset GBM. [cov] is the return covariance matrix; it is Cholesky-factorized
    once and reused for every step. Returns one price path per asset.

    Use this rather than generating each asset independently whenever the strategy trades a
    relationship — independent paths contain no relationship to trade. *)
val multivariate_gbm :
  rng:Rng.t ->
  s0:float array ->
  mu:float array ->
  cov:float array array ->
  n:int ->
  dt:float ->
  (float array array, [ `Not_positive_definite of int | `Not_square of int * int ]) Stdlib.result

(** Compound a return series into prices starting from [s0]. *)
val prices_of_returns : s0:float -> returns:float array -> float array

(** {2 Bridging into a backtest} *)

(** Turn a price path into tick records. A symmetric [spread_bps] quote is synthesized around each
    price. Adequate whenever the fill model does not need depth. *)
val to_records :
  symbol:string ->
  prices:float array ->
  start_ts_ns:int64 ->
  step_ns:int64 ->
  ?spread_bps:float ->
  ?volume:float ->
  unit ->
  Algostream_backtest.Data_source.record array

(** As {!to_records}, but also emits a synthetic [levels]-deep book at each step, for fill models
    that walk depth.

    {b Cost warning.} [Order_book] has no incremental update, so the whole book is rebuilt every
    step — O(levels) allocation per step, and the dominant cost of book-mode Monte Carlo. Prefer
    {!to_records} unless the fill model genuinely needs depth. *)
val to_records_with_book :
  symbol:string ->
  prices:float array ->
  start_ts_ns:int64 ->
  step_ns:int64 ->
  levels:int ->
  level_size:float ->
  tick_size:float ->
  ?volume:float ->
  unit ->
  Algostream_backtest.Data_source.record array
