(** Seedable pseudo-random generator for simulation.

    xoshiro256++ driven by a SplitMix64 seed expansion. Chosen over the pre-existing
    [Math_utils.FastRandom] xorshift128, which is unusable for Monte Carlo work: its constructor
    seeds only the first of four state words and leaves the other three at fixed constants, so
    nearby seeds — precisely the [1 .. n_runs] pattern a simulation batch uses — produce heavily
    correlated streams. SplitMix64 has full avalanche on the seed, so {!substream} yields
    effectively independent state for every distinct [(root_seed, index)] pair.

    {b Determinism contract.} [substream ~root_seed ~index] is a pure function of its arguments. Run
    [k] of a batch therefore draws the same numbers no matter how many Domains execute the batch, in
    what order they are scheduled, or whether the batch is re-run later with a different degree of
    parallelism. This is what makes {!Algostream_montecarlo.Pool} results reproducible.

    A [t] is mutable and is {b not} thread- or Domain-safe. Give each Domain its own — that is what
    {!substream} is for. *)

type t

(** Expand [seed] through SplitMix64 into a full 256-bit state. Every [int] seed is acceptable,
    including [0] and negatives; there is no degenerate all-zero state. *)
val create : seed:int -> t

(** The batch primitive: derive the generator for run [index] of a batch rooted at [root_seed].
    Distinct [index] values give streams with no detectable correlation, and the result does not
    depend on any generator having been drawn from previously. *)
val substream : root_seed:int64 -> index:int -> t

(** Draw a fresh independent generator from [t], advancing [t]. Useful when a single run needs
    several conceptually separate noise sources (price path vs. latency jitter) and you want them
    decoupled. *)
val split : t -> t

(** Independent copy; the copy and the original then produce identical sequences. *)
val copy : t -> t

(** Raw 64 bits. *)
val bits : t -> int64

(** Uniform on [\[0, 1)] — 53-bit mantissa resolution. May return exactly [0.0]. *)
val uniform : t -> float

(** Uniform on the {b open} interval [(0, 1)]. Never returns [0.0] or [1.0], so [log] of the result
    is always finite. {!Variate.normal} uses this; [Math_utils.FastRandom.normal_sample] does not,
    which is why it can emit [nan]. *)
val uniform_pos : t -> float

(** Uniform on [\[lo, hi)]. Returns [lo] when [hi <= lo]. *)
val uniform_range : t -> lo:float -> hi:float -> float

(** Uniform integer on [\[0, n)] by Lemire's multiply-shift with rejection, so the result is
    unbiased rather than modulo-skewed. Raises [Invalid_argument] if [n <= 0]. *)
val int_below : t -> int -> int

(** In-place Fisher-Yates shuffle. *)
val shuffle : t -> 'a array -> unit
