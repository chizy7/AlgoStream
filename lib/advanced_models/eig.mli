(** Jacobi symmetric eigendecomposition for small dense matrices.

    Numerically stable on symmetric input. Sweep over off-diagonal pairs, each pair zeroed by a
    Givens rotation that's also applied to the running eigenvector matrix. Default convergence:
    off-diagonal Frobenius norm ≤ [tol · frob_norm(input)]. Caps at [max_iter] sweeps (default 100)
    and reports [converged = false] if unmet.

    Eigenvalues are returned in descending order; the [k]-th column of [eigenvectors] is the
    eigenvector for [eigenvalues.(k)]. *)

type result = {
  eigenvalues : float array;
  eigenvectors : float array array;
  iter : int;
  converged : bool;
}

val jacobi_sym : ?max_iter:int -> ?tol:float -> matrix:float array array -> unit -> result
