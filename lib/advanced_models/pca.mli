(** Principal Component Analysis via Jacobi eigendecomposition of the sample covariance.

    Input data is a [n × p] matrix in row-major form: [data.(i).(j)] is the [j]-th feature of the
    [i]-th observation. [fit] centres columns by their mean before computing the covariance.

    Components are returned in descending order of explained variance. [components.(k)] is the
    [k]-th principal axis (an eigenvector of length [p]).

    [transform] projects centred data onto the components → an [n × n_components] matrix.
    [inverse_transform] reconstructs the centred data from the projection and adds back the column
    means. *)

type t

val fit : data:float array array -> ?n_components:int -> unit -> t

val n_components : t -> int

val n_features : t -> int

val n_samples : t -> int

val explained_variance : t -> float array

val explained_variance_ratio : t -> float array

val components : t -> float array array

val transform : t -> data:float array array -> float array array

val inverse_transform : t -> projected:float array array -> float array array
