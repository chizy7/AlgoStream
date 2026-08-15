(** Read-only view of the world, handed to the strategy on every event.

    Market and portfolio state are exposed as {b accessor closures} rather than as handed-out
    hashtables. The engine owns the mutable state; a strategy that received the table itself could
    corrupt the engine's bookkeeping, and a strategy that received a copy would pay for a snapshot
    on every event. Closures give O(1) reads with no ownership transfer.

    [ts_ns] is the strategy's only legitimate "now". [lib/strategy] is on the wall-clock lint list,
    so there is no other source available. *)

module Portfolio = Algostream_domain_portfolio.Portfolio
module Order = Algostream_domain_orders.Order
module Order_book = Algostream_domain_market.Order_book

type t = {
  ts_ns : int64;  (** current event time *)
  seq : int;  (** monotone event counter within the run; useful for tie-breaking and diagnostics *)
  portfolio : Portfolio.portfolio;
  nav : float;  (** cash + marked-to-market positions *)
  working_orders : Order.order list;  (** live orders at the venue, in submission order *)
  position : string -> float;  (** signed quantity; [0.0] when flat or unknown *)
  last_price : string -> float option;
  quote : string -> (float * float) option;  (** [(bid, ask)] *)
  book : string -> Order_book.order_book option;
  risk : Algostream_risk_management.Risk_snapshot.t option;
    (** [None] when the engine was configured without a risk monitor *)
}

(** Mid price from {!quote}, falling back to {!last_price} when only one side is known. *)
val mid : t -> string -> float option

(** Half-spread in basis points of mid, when both sides are known. *)
val half_spread_bps : t -> string -> float option

(** Whether the strategy currently holds a non-flat position in [symbol]. *)
val has_position : t -> string -> bool

(** Working orders filtered to one symbol. *)
val working_for : t -> string -> Order.order list
