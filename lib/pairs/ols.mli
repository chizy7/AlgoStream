(** Small-dim ordinary least squares via Gram matrix + Cholesky.

    Designed for [p ≤ 5] regressors — the ADF and AR(1) half-life fits used by this library. A
    Tikhonov ridge of [1e-12 · I] is added before factorization so a singular Gram matrix becomes a
    clean [`Singular] error rather than a NaN cascade. Regressors are NOT auto-centred; callers that
    include an intercept column must hand it a column of ones. *)

type fit = {
  beta : float array;
  se : float array;  (** standard errors of beta *)
  rss : float;
  tss : float;
  n : int;
  p : int;
}

type error =
  [ `Singular
  | `Underdetermined of int * int  (** n, p *)
  ]

(** Solve [A · β = y] in the least-squares sense, returning β and per-coefficient SE. [x] is
    row-major: [x.(i).(j)] is the [j]-th regressor for the [i]-th observation. *)
val solve : x:float array array -> y:float array -> p:int -> (fit, error) result

(** Convenience: simple intercept-plus-slope regression. Returns [(intercept, slope, r_squared)]. *)
val regress2 : x:float array -> y:float array -> (float * float * float, error) result
