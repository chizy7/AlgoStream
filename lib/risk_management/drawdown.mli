(** Streaming drawdown tracker.

    Online complement to
    {!Algostream_domain_portfolio.Portfolio.Risk_metrics.calculate_maximum_drawdown} (which computes
    max-DD offline over a NAV history). [Tracker.update] consumes one equity point at a time and
    maintains running peak / current DD / max DD / time under water.

    Out-of-order updates (older [ts_ns]) are silently ignored — we don't rewind. *)

module Tracker : sig
  type t

  val create : ?initial_equity:float -> unit -> t

  val update : t -> equity:float -> ts_ns:int64 -> unit

  val peak_equity : t -> float

  (** Fractional drawdown from the running peak. 0.0 when equity is at or above the peak. *)
  val current_drawdown : t -> float

  val max_drawdown : t -> float

  (** Nanoseconds since equity dropped below the peak. 0L when at/above peak. *)
  val time_under_water_ns : t -> int64

  val n_updates : t -> int
end
