(** Special functions for hypothesis testing and statistical distributions.

    All approximations are intentionally coarse — sufficient for the ≤ 2-significant-figure p-values
    we surface elsewhere in the project (cf. [Pairs.Mackinnon_cv]). For research-grade precision use
    a dedicated stats package. *)

(** Error function. Abramowitz & Stegun 7.1.26 — max abs error ~1.5e-7. *)
val erf : float -> float

(** Complementary error function. *)
val erfc : float -> float

(** Standard normal CDF P(Z ≤ x). *)
val normal_cdf : x:float -> float

(** Standard normal PDF. *)
val normal_pdf : x:float -> float

(** Inverse standard normal CDF (Beasley-Springer-Moro). [p] must be in (0, 1). Max abs error ~3e-9
    in the central region. *)
val normal_quantile : p:float -> float

(** Logarithm of the Gamma function. Lanczos approximation, ~15-digit precision for x > 0; uses the
    reflection formula for x < 0.5. *)
val log_gamma : float -> float

(** Regularized lower incomplete gamma P(s, x) = γ(s, x) / Γ(s). [s > 0], [x ≥ 0]. *)
val incomplete_gamma_p : s:float -> x:float -> float

(** Regularized upper incomplete gamma Q(s, x) = Γ(s, x) / Γ(s) = 1 − P(s, x). *)
val incomplete_gamma_q : s:float -> x:float -> float

(** Regularized incomplete beta function I_x(a, b). [x ∈ [0, 1]], [a > 0], [b > 0]. Drives the
    Student's t CDF. *)
val regularized_beta : x:float -> a:float -> b:float -> float
