(** Augmented Dickey-Fuller unit-root test.

    Regression: [Δy_t = α + ρ y_{t-1} + Σ_{i=1..lag} γ_i Δy_{t-i} (+ β t) + ε_t]. The test statistic
    is the t-ratio on [ρ]; under the null [ρ = 0] (random walk) it follows a non-standard
    distribution with critical values from MacKinnon (1996). p-values are coarse interpolations
    between the embedded 1%/5%/10% anchors — see [Mackinnon_cv]. *)

type variant = Config.adf_variant =
  | No_constant
  | With_constant
  | With_trend

type result = {
  t_stat : float;
  lag : int;
  n : int;
  p_value : float;
  variant : variant;
}

type error = [ `Insufficient_data of int * int  (** have, need *) ]

(** Run the ADF regression on [series]. Default [variant = With_constant], [lag = 1]. *)
val test : ?variant:variant -> ?lag:int -> float array -> (result, error) Stdlib.result

(** Schwert's rule: [floor(12 · (n/100)^0.25)], capped at 4 to keep [p ≤ 5] for [Ols.solve]. *)
val schwert_lag : n:int -> int

val empty_result : result
