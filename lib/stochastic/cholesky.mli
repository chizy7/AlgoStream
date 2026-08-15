(** Cholesky factorization [A = L · Lᵀ] for symmetric positive-definite [A].

    A Cholesky already exists in the tree but is trapped inside [Algostream_pairs.Ols.solve], where
    it factorizes a Gram matrix and is not exposed. Correlated multi-asset scenario generation needs
    the factor itself, so it lives here as a first-class value.

    Only the lower triangle of the input is read; the caller's matrix is never mutated. *)

type error =
  [ `Not_square of int * int  (** rows, cols *)
  | `Not_positive_definite of int  (** leading-minor index at which the pivot went non-positive *)
  ]

(** Exact factorization. Returns the lower-triangular [l] with [l.(i).(j) = 0] for [j > i]. *)
val factor : float array array -> (float array array, error) Stdlib.result

(** Factorization with a Tikhonov ridge of [jitter · I] added to the diagonal first, mirroring the
    [1e-12 · I] that [Ols.solve] applies for the same reason.

    Correlation matrices estimated from finite samples are routinely indefinite by a rounding
    epsilon; a ridge turns that into a clean factorization instead of a spurious
    [`Not_positive_definite]. It does {b not} rescue a genuinely indefinite matrix — the ridge is
    small by design, and a matrix with a materially negative eigenvalue still fails. Default
    [jitter = 1e-10]. *)
val factor_jittered : ?jitter:float -> float array array -> (float array array, error) Stdlib.result

(** [apply ~lower z] computes [L · z] — the standard way to turn a vector of iid standard normals
    into one with covariance [A]. Raises [Invalid_argument] on a length mismatch. *)
val apply : lower:float array array -> float array -> float array

(** [correlation_to_covariance ~corr ~stddev] scales a correlation matrix into a covariance matrix:
    [cov.(i).(j) = corr.(i).(j) · σ_i · σ_j]. *)
val correlation_to_covariance : corr:float array array -> stddev:float array -> float array array
