(** Bivariate state-space Kalman filter over the hedge regression [y_t = α_t + β_t · x_t + ε_t].

    State [(α, β)] follows a random walk with diagonal process noise [Q = diag(Q_α, Q_β)]; the
    measurement noise variance is [R]. The 2×2 covariance update uses the Joseph form so the
    posterior covariance stays symmetric and PSD.

    Returns a fresh {!state} record on every {!update} call (no aliasing of internal storage).
    Suitable for use as a sharper β estimator inside a strategy: feed [(y_t, x_t)] pairs from each
    tick and read [state.beta] directly. *)

type state = {
  alpha : float;
  beta : float;
  cov : float array array;  (** 2×2 posterior covariance *)
}

type t

val create :
  ?initial_alpha:float ->
  ?initial_beta:float ->
  ?initial_cov:float ->
  ?process_var_alpha:float ->
  ?process_var_beta:float ->
  ?measurement_var:float ->
  unit ->
  t

(** Apply one observation [(y, x)] and return the updated state. *)
val update : t -> y:float -> x:float -> state

val state : t -> state

val n_updates : t -> int
