(** Execution latency simulation.

    [Venue.base_latency_us] is read by nothing else. This module is its first consumer. Without it a
    backtest fills against the very tick that triggered the decision, which is the single most
    flattering and least realistic assumption a simulator can make.

    Four delays, all in event time:

    - [decision_to_venue_ns] — strategy emits an action → the venue receives it
    - [venue_match_ns] — venue receipt → the order is eligible to match
    - [fill_to_strategy_ns] — the fill happens → the strategy is told about it
    - [cancel_to_venue_ns] — a cancel is issued → the venue applies it (a cancel racing a fill is
      how real orders get filled after you tried to pull them, and this reproduces that)

    Jitter is drawn from the caller's [Rng.t]. The engine holds a {i separate} substream for
    execution noise from the one driving the price path, so changing the latency model does not
    shift the data a Monte Carlo comparison runs on — common random numbers. *)

module Venue = Algostream_order_management.Venue
module Rng = Algostream_rng.Rng

type t = {
  decision_to_venue_ns : int64;
  venue_match_ns : int64;
  fill_to_strategy_ns : int64;
  cancel_to_venue_ns : int64;
  jitter_ns : int64;  (** symmetric: the actual delay is uniform on [±jitter_ns] around the base *)
}

(** All delays zero. For unit tests that want to isolate the fill logic, and for the "perfect
    execution" upper bound a strategy's real result should be compared against. *)
val zero : t

(** Derive from a venue's published latency. [decision_to_venue_ns] seeds from
    [venue.base_latency_us × 1000]; the match and inbound legs default to a quarter and a half of
    that respectively, which is the usual shape (matching is fast, market data dissemination is
    not). Override any of them explicitly. *)
val of_venue : Venue.t -> ?jitter_ns:int64 -> unit -> t

(** Outbound delay for a new order: [decision_to_venue_ns + venue_match_ns], jittered. *)
val outbound : t -> rng:Rng.t -> int64

(** Inbound delay for a fill report: [fill_to_strategy_ns], jittered. *)
val inbound : t -> rng:Rng.t -> int64

(** Outbound delay for a cancel: [cancel_to_venue_ns], jittered. *)
val cancel : t -> rng:Rng.t -> int64

val to_string : t -> string
