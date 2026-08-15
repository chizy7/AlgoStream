(** Bootstrap resampling for historical series.

    Four variants, in increasing order of how much serial structure they preserve:

    - {!iid} — draw observations independently. Destroys all autocorrelation, including volatility
      clustering. Correct only for series that really are iid; for financial returns it produces
      drawdown distributions that are far too benign.
    - {!moving_block} — draw fixed-length contiguous blocks. Preserves dependence up to the block
      length. Under-samples observations near the ends of the series.
    - {!circular_block} — as above but the series wraps, so every observation is equally likely.
    - {!stationary} — Politis & Romano (1994): geometric block lengths with circular wrap. The
      resampled series is genuinely stationary, which the fixed-length variants are not.

    {b Block length matters more than the variant.} Too short and dependence is destroyed anyway;
    too long and there are too few distinct blocks for the resamples to differ. {!rule_of_thumb}
    gives the standard [n^(1/3)] starting point. The automatic Politis-White selector is
    deliberately not implemented — it needs a flat-top-kernel spectral density estimate that we are
    not going to hand-roll to a defensible standard, and a wrong automatic answer is worse than an
    explicit rule of thumb. *)

module Rng = Algostream_rng.Rng

(** [iid rng ~data ~n] draws [n] observations with replacement. *)
val iid : Rng.t -> data:float array -> n:int -> float array

(** Fixed-length blocks, no wrap. Start indices are uniform on [[0, length data - block_len]]. *)
val moving_block : Rng.t -> data:float array -> block_len:int -> n:int -> float array

(** Fixed-length blocks with circular wrap — every observation appears with equal probability. *)
val circular_block : Rng.t -> data:float array -> block_len:int -> n:int -> float array

(** Politis-Romano stationary bootstrap. Block lengths are Geometric with mean [mean_block_len];
    wraps circularly. *)
val stationary : Rng.t -> data:float array -> mean_block_len:float -> n:int -> float array

(** [n^(1/3)] rounded, floored at 1 — the conventional starting point for block length. Tune it
    against the series' autocorrelation rather than trusting it blindly. *)
val rule_of_thumb : n:int -> int

(** {2 Cross-sectional resampling}

    {!joint_index} is the one that matters for pairs trading and is easy to get catastrophically
    wrong. Bootstrapping each leg of a pair {i independently} destroys the cointegration the
    strategy exists to trade, so the resampled world contains no tradable relationship and the Monte
    Carlo reports a strategy that cannot possibly work. Resampling the shared {i time index} and
    applying it to every series preserves the cross-sectional structure while still randomizing the
    path.

    Always use this for multi-asset scenarios. *)

(** [joint_index rng ~n_source ~n ~block_len] returns [n] indices into [\[0, n_source)] drawn as
    circular blocks. Apply the same index array to every series. [block_len <= 1] degenerates to iid
    index resampling. *)
val joint_index : Rng.t -> n_source:int -> n:int -> block_len:int -> int array

(** Apply an index array produced by {!joint_index} (or any index array) to a series. Raises
    [Invalid_argument] if any index is out of range. *)
val take : data:float array -> idx:int array -> float array

(** {2 Randomization tests} *)

(** Uniformly random permutation (a copy; the input is not mutated). *)
val permute : Rng.t -> 'a array -> 'a array

(** Multiply each element by a random ±1. The standard randomization test for "is this mean
    distinguishable from zero" under a symmetry assumption. *)
val sign_flip : Rng.t -> float array -> float array
