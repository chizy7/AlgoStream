(** Outlier-detection pipeline.

    Filters compose left-to-right; the first [Reject] short-circuits. Order matters: [Sanity] must
    always come first to prevent NaN/Inf from poisoning later moment-based filters. *)

type verdict =
  | Pass
  | Reject of {
      reason : string;
      severity : int; (* 1 = mild (z-score reject), 2 = moderate, 3 = critical (sanity) *)
    }

(* Each filter is stateful (mutable accumulators); call [update] per tick. *)
module type FILTER = sig
  type t

  val name : string

  val update : t -> float -> verdict
end

(* ───── concrete filters ──────────────────────────────────────────── *)

module Sanity : FILTER

val sanity : Sanity.t

module Z_score : sig
  include FILTER

  val create : threshold:float -> warmup:int -> ewma_period:int -> t
end

module Hampel : sig
  include FILTER

  val create : threshold:float -> warmup:int -> window:int -> t
end

(* ───── pipeline runner ───────────────────────────────────────────── *)

(** Wrap a concrete filter into an opaque update function. *)
type runner = float -> verdict

val wrap : (module FILTER with type t = 't) -> 't -> runner

(** Run the chain in order; returns the first [Reject], else [Pass]. *)
val run : runner list -> float -> verdict
