(** Random variate samplers over {!Rng}.

    All samplers are {b stateless with respect to the caller}: the only mutable state is the [Rng.t]
    itself. In particular {!normal} does not cache the second Box-Muller branch. Caching would be
    ~2× faster, but it puts a spare value somewhere outside the [Rng.t] — which [Rng.copy] does not
    copy and [Rng.substream] does not derive — so a cached generator's output would depend on call
    history in a way that quietly breaks the substream reproducibility contract. Callers who want
    both branches ask for {!normal_pair} and get them explicitly.

    Every sampler draws from [Rng.uniform_pos] rather than [Rng.uniform] wherever a [log] or a
    division is involved, so [nan] cannot arise from a boundary draw. *)

module Rng = Algostream_rng.Rng

(** Standard normal, N(0, 1). Box-Muller in trigonometric form; the sine branch is discarded (see
    the header). Consumes two uniforms. *)
val normal : Rng.t -> float

(** Both Box-Muller branches. Consumes two uniforms and returns two independent standard normals —
    use this in a loop filling an even-length buffer. *)
val normal_pair : Rng.t -> float * float

(** N(mu, sigma²). [sigma] is a standard deviation, not a variance. *)
val gaussian : Rng.t -> mu:float -> sigma:float -> float

(** [normal_array rng ~n] fills an array using {!normal_pair}, so it costs [n] uniforms rather than
    [2n]. *)
val normal_array : Rng.t -> n:int -> float array

(** Exponential with rate [lambda] (mean [1 / lambda]). Inverse-CDF. *)
val exponential : Rng.t -> lambda:float -> float

(** Gamma(shape, scale) by Marsaglia & Tsang (2000), "A Simple Method for Generating Gamma
    Variables", with the Johnk boost for [shape < 1]. Raises [Invalid_argument] for non-positive
    [shape] or [scale]. *)
val gamma : Rng.t -> shape:float -> scale:float -> float

(** Chi-squared with [df] degrees of freedom — Gamma(df/2, 2). *)
val chi_squared : Rng.t -> df:float -> float

(** Student-t with [df] degrees of freedom, as [Z / sqrt(X / df)] with [Z] standard normal and [X]
    chi-squared. Heavier tails than normal — the right innovation distribution when a scenario
    generator should produce realistic tail events. *)
val student_t : Rng.t -> df:float -> float

(** Log-normal: [exp(mu + sigma · Z)]. Note [mu] and [sigma] parameterize the {i underlying normal},
    not the log-normal's own mean and standard deviation. *)
val lognormal : Rng.t -> mu:float -> sigma:float -> float

(** Bernoulli. Returns [true] with probability [p]; clamps [p] into [[0, 1]]. *)
val bernoulli : Rng.t -> p:float -> bool

(** Poisson with mean [lambda]. Knuth's product method below [lambda = 30], normal approximation
    with continuity correction above it — the approximation is documented rather than hidden because
    the exact method's cost grows linearly in [lambda]. *)
val poisson : Rng.t -> lambda:float -> int

(** [multivariate_normal rng ~mean ~chol_lower] returns [mean + L · z] with [z] a vector of iid
    standard normals. [chol_lower] comes from {!Cholesky.factor} (or {!Cholesky.factor_jittered}) of
    the target covariance matrix — factorize once, sample many times. Raises [Invalid_argument] on a
    dimension mismatch. *)
val multivariate_normal : Rng.t -> mean:float array -> chol_lower:float array array -> float array

(** Index sampled proportionally to [weights] by linear-scan inverse CDF. Negative weights are
    treated as zero. Returns [0] if every weight is zero. O(n) per draw — fine for the small
    categorical draws this library needs (regime transitions); a caller doing millions of draws from
    one fixed distribution should build an alias table. *)
val choose_weighted : Rng.t -> weights:float array -> int
