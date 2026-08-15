(** Strategy-versus-benchmark comparison: alpha, beta, tracking error, capture ratios.

    None of these exist elsewhere in the tree. [Portfolio.Risk_metrics.calculate_risk_metrics] takes
    an optional [~benchmark_returns] and produces a [beta], which is the only prior art; everything
    else here is new.

    The two series must be sampled on the same grid and are truncated to the shorter length. *)

type t = {
  n_periods : int;
  alpha_ann : float;  (** Jensen's alpha, annualized *)
  beta : float;
  r_squared : float;
  correlation : float;
  tracking_error_ann : float;  (** annualized stddev of the active return *)
  information_ratio : float;  (** [active_return_ann / tracking_error_ann] *)
  active_return_ann : float;
  up_capture : float;  (** strategy mean / benchmark mean over up-benchmark periods *)
  down_capture : float;
  capture_ratio : float;  (** [up_capture / down_capture]; > 1 is the desirable asymmetry *)
  treynor : float;  (** [(ann_return - risk_free) / beta] *)
}

val empty : t

val compare :
  strategy:float array ->
  benchmark:float array ->
  periods_per_year:float ->
  ?risk_free_rate_ann:float ->
  unit ->
  t

val to_string : t -> string
