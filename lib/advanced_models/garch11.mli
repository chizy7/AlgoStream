(** Variance-targeting GARCH(1,1) for forward-looking volatility forecasting.

    Model: sigma2 at time t equals omega + alpha * (return at t-1)^2 + beta * (sigma2 at t-1), with
    long-run variance equal to omega / (1 - alpha - beta). Variance targeting fixes omega =
    sample_variance * (1 - alpha - beta), reducing the maximum-likelihood fit to a two-parameter
    optimization over (alpha, beta) on the stationarity simplex (alpha >= 0, beta >= 0, alpha + beta
    < 1). Optimization is by Nelder-Mead with multiple restarts. *)

type params = {
  omega : float;
  alpha : float;
  beta : float;
}

type fit_result = {
  params : params;
  log_likelihood : float;
  iter : int;
  converged : bool;
  long_run_variance : float;
}

type fit_error =
  [ `Insufficient_data of int * int  (** have, need *)
  | `Not_converged
  ]

(** Quasi-MLE under Gaussian innovations. Returns [Error] if [returns] has fewer than 32 entries or
    if no restart converged. *)
val fit :
  returns:float array ->
  ?max_iter:int ->
  ?tol:float ->
  unit ->
  (fit_result, fit_error) Stdlib.result

type t

val of_fit : fit_result -> last_return:float -> last_variance:float -> t

(** Apply one new return; returns the next σ² forecast. *)
val update : t -> r:float -> float

val current_variance : t -> float

(** Multi-step sigma2 forecasts at horizons 1, 2, ..., [horizon]. Mean-reverts to the long-run
    variance at rate (alpha + beta). *)
val forecast : t -> horizon:int -> float array
