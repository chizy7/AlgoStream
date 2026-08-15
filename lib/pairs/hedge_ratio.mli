(** β estimator for the spread regression [y ≈ β·x + α].

    Three modes (selected via [Config.beta_mode]):
    - [Static of float] — fixed β, no online update; intercept fixed at 0.
    - [Rolling_ols] — closed-form rolling [cov(x,y) / var(x)] over [Config.beta_window], with
      periodic full recompute to bound floating-point drift.
    - [Kalman_smoothed] — runs [Filters.Kalman1d] over the rolling-OLS β estimate, so the reported
      [beta] is a low-pass-filtered version of the noisy OLS estimate.

    If [Rolling_var(x) < 1e-12] (a flat regressor), β is held at its previous value and
    [beta_frozen_ticks] increments — avoids divide-by-near-zero blow-ups in calm regimes. *)

type t

val create : Config.t -> t

(** Returns the updated [(beta, intercept)] after observing one paired sample. *)
val update : t -> x:float -> y:float -> float * float

val beta : t -> float

val intercept : t -> float

(** Trailing standard deviation of β across the most recent [beta_window/4] updates. Used by
    [Selection] to screen out pairs with an unstable hedge ratio. *)
val beta_stdev : t -> float

val n_updates : t -> int

val beta_frozen_ticks : t -> int

val ready : t -> bool
