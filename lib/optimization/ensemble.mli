(** Combining strategies, and measuring whether the combination actually diversifies.

    {b Rolling weights, not full-sample weights.} Fitting minimum-variance weights on the whole
    sample and reporting the resulting Sharpe is in-sample optimization wearing a diversification
    costume — the covariance you optimized against is the one you measured. {!rolling_combine}
    re-estimates on a trailing window and applies the weights forward, which is the version whose
    numbers mean something. {!combine} exists for the one-shot case and says so. *)

module Metrics = Algostream_performance.Metrics

type weighting =
  | Equal
  | Inverse_volatility
  | Sharpe_weighted  (** proportional to positive Sharpe; a member with negative Sharpe gets zero *)
  | Risk_parity  (** equal marginal risk contribution, by fixed-point iteration *)
  | Min_variance
    (** analytic [Σ⁻¹1 / 1'Σ⁻¹1] via Cholesky, then clipped to long-only and renormalized.

        {b The clip makes it approximate.} An exact long-only minimum-variance portfolio is a
        quadratic program, and adding a QP solver for one function was not worth a new dependency.
        When the unconstrained solution is already non-negative — common for weakly correlated
        members — the clip does nothing and the answer is exact. *)
  | Custom of float array

type member = {
  name : string;
  returns : float array;
}

type result = {
  weights : (string * float) array;
  combined : Metrics.t;
  diversification_ratio : float;
    (** weighted average volatility / portfolio volatility; > 1 is the point *)
  effective_n : float;  (** [1 / Σwᵢ²]; how many members you are *effectively* holding *)
  avg_pairwise_correlation : float;
  marginal_risk_contribution : (string * float) array;
  incremental_sharpe : (string * float) array;
    (** change in combined Sharpe from dropping each member. Negative means the member is
        subtracting value even if its standalone Sharpe is positive. *)
  correlation_matrix : float array array;
}

type error =
  [ `Empty
  | `Length_mismatch
  | `Not_positive_definite of int
  ]

(** One-shot combination over the full sample. In-sample by construction — see the header. *)
val combine :
  members:member array ->
  weighting:weighting ->
  periods_per_year:float ->
  ?risk_free_rate_ann:float ->
  unit ->
  (result, error) Stdlib.result

(** Weights re-estimated on a trailing [lookback] window and rebalanced every [rebalance_every]
    periods, then applied forward. The honest version. *)
val rolling_combine :
  members:member array ->
  weighting:weighting ->
  lookback:int ->
  rebalance_every:int ->
  periods_per_year:float ->
  ?risk_free_rate_ann:float ->
  unit ->
  (result, error) Stdlib.result

(** Greedily select members whose pairwise correlation with those already chosen stays below
    [max_corr], up to [max_n]. A cheap pre-filter before weighting. *)
val select_uncorrelated : members:member array -> max_corr:float -> max_n:int -> string array

val result_to_string : result -> string
