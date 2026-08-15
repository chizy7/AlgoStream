(** Mean-reversion signal classifier + half-life estimator.

    The classifier is a stateful band crossover over the spread z-score:
    - Flat → [Long_spread] when [z ≤ -entry_z]; → [Short_spread] when [z ≥ entry_z]; else [Hold].
    - Long → [Exit] when [z ≥ -exit_z] (target reached) or [|z| ≥ stop_z] (stop-out); else [Hold].
    - Short → [Exit] when [z ≤ exit_z] (target reached) or [|z| ≥ stop_z] (stop-out); else [Hold].

    The half-life estimator runs OLS of [Δr_t] on [r_{t-1}] with intercept: [φ̂ = 1 + slope];
    half-life = [-ln 2 / ln |φ̂|]. Returns [`Non_reverting] if [|φ̂| ≥ 1]. *)

type signal =
  | Long_spread
  | Short_spread
  | Exit
  | Hold

type t

val create : entry_z:float -> exit_z:float -> stop_z:float -> t

val update : t -> z:float -> signal

val position : t -> [ `Flat | `Long | `Short ]

type half_life_error =
  [ `Insufficient_data of int * int
  | `Non_reverting
  | `Ols of Ols.error
  ]

val half_life : residuals:float array -> (float, half_life_error) result

type significance =
  | Significant of float
  | Marginal
  | Non_reverting

val significance : Adf.result -> significance

val signal_to_string : signal -> string
