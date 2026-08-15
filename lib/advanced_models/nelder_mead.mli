(** Derivative-free Nelder-Mead simplex minimizer for small fixed dimensions.

    Designed for the n ≤ 4 problems that arise in this codebase (GARCH likelihood, model
    calibration). For higher-dim or constrained problems, use a real optimization library. *)

type config = {
  max_iter : int;
  tol_x : float;
  tol_f : float;
  alpha : float;  (** reflection coefficient *)
  gamma : float;  (** expansion coefficient *)
  rho : float;  (** contraction coefficient *)
  sigma : float;  (** shrink coefficient *)
}

val default_config : config

type result = {
  x : float array;
  f : float;
  iter : int;
  converged : bool;
}

(** Minimize [f] starting from initial guess [x0]. The simplex is built by perturbing each
    coordinate by 5% (or 2.5e-4 if the coordinate is near zero). *)
val minimize : f:(float array -> float) -> x0:float array -> ?config:config -> unit -> result
