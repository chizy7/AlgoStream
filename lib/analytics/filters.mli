(** Noise-filtering / smoothing primitives.

    All filters are streaming, mutable, single-writer. None of them block. Numerical contracts:

    - [Sanity.check] rejects any non-finite, zero, or negative price/size BEFORE downstream filters
      can see them — prevents NaN propagation through EWMA/Kalman/Welford.
    - [Ewma] uses RiskMetrics-style bias correction so early samples are not refused outright but
      report a [ready] flag when the bias is no longer load-bearing.
    - [Kalman1d] is a local-level model (state = true mid, observation = noisy tick); Q and R
      bootstrap from a warmup window of tick-to-tick log-returns, exposed via
      [signal_to_noise_ratio = Q / R]. *)

(* ───── Sanity (range/finiteness) ──────────────────────────────────── *)

module Sanity : sig
  type verdict =
    | Ok
    | Reject of string

  (** Pure function. Returns [Ok] iff price and size are both finite and strictly positive. *)
  val check : price:float -> size:float -> verdict
end

(* ───── EWMA with bias correction ──────────────────────────────────── *)

module Ewma : sig
  type t

  val create : period:int -> t

  (** Returns the bias-corrected EWMA after consuming [x]. *)
  val update : t -> float -> float

  val value : t -> float

  (** True once the bias-correction weight reaches 0.95 (≈ 3·period samples). *)
  val ready : t -> bool

  val n : t -> int
end

(* ───── EWMA variance (matched bias correction) ────────────────────── *)

module Ewma_var : sig
  type t

  val create : period:int -> t

  (** Update with a new observation; returns the bias-corrected EWMA variance. *)
  val update : t -> float -> float

  val value : t -> float

  val std_dev : t -> float

  val ready : t -> bool
end

(* ───── 1-D Kalman filter (local-level) ────────────────────────────── *)

module Kalman1d : sig
  type t

  val create : signal_to_noise_ratio:float -> warmup:int -> t

  (** Update with a new observation; returns the posterior estimate of the state. During warmup
      [Q]/[R] are still being calibrated; the function still returns a sensible smoothed value but
      [ready] is false. *)
  val update : t -> float -> float

  val value : t -> float

  val variance : t -> float

  val ready : t -> bool

  (** Force a Q/R recalibration from accumulated residuals — call on regime transitions. *)
  val recalibrate : t -> unit
end

(* ───── Median over a fixed window (Hampel pre-step) ───────────────── *)

module Median_window : sig
  type t

  val create : window:int -> t

  (** Returns the running median over the most recent [window] samples (sorted-copy at query time;
      O(N log N) per call; N is small so this is fine for our use). *)
  val update : t -> float -> float

  (** Median absolute deviation over the window; required for Hampel. *)
  val mad : t -> float

  val n : t -> int
end
