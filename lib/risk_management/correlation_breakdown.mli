(** Detect when a tracked correlation drifts away from its baseline.

    Two EWMAs over the correlation feed: a long-period [baseline] (default 60) and a short-period
    [current] (default 10). The status ladder reports increasing severity:

    - [Stable] — current is within [breakdown_threshold/2] of baseline
    - [Weakening] — diff > threshold/2 but < threshold
    - [Broken_down] — diff ≥ threshold
    - [Sign_flipped] — current and baseline have opposite signs AND |current| > threshold (overrides
      the other levels)

    Built on top of [Algostream_analytics.Filters.Ewma]. *)

type status =
  | Stable
  | Weakening of float  (** current corr value *)
  | Broken_down of float
  | Sign_flipped of float

module Detector : sig
  type t

  val create :
    ?baseline_period:int -> ?current_period:int -> ?breakdown_threshold:float -> unit -> t

  val update : t -> correlation:float -> status

  val baseline : t -> float

  val current : t -> float

  val status : t -> status
end

val status_to_string : status -> string
