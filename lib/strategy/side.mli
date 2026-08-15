(** The one place trade direction gets converted.

    Direction is represented three different ways in the domain layer, and any fill pipeline has to
    cross all three:

    - [Algostream_domain_orders.Order.order_side] — a nominal variant, [Buy | Sell]
    - [Algostream_domain_trades.Trade.side] — a {i polymorphic} variant, [`Buy | `Sell]
    - [Position.add_trade] / [Portfolio.add_trade] — a {b signed float quantity}, negative for sells

    Unifying those three would ripple through most of the test suite, so the representations stay as
    they are and every conversion goes through this module instead. If a sign flips somewhere, it
    flipped here. *)

type t = Algostream_domain_orders.Order.order_side =
  | Buy
  | Sell

val of_trade_side : [ `Buy | `Sell ] -> t

val to_trade_side : t -> [ `Buy | `Sell ]

(** [Buy] → [1.0], [Sell] → [-1.0]. *)
val sign : t -> float

(** [signed side ~qty] applies {!sign} to a {b positive} quantity, producing the signed value
    [Portfolio.add_trade] expects. A negative [qty] is treated as its magnitude — the side argument
    is authoritative, so callers cannot accidentally double-negate. *)
val signed : t -> qty:float -> float

(** Recover a side from a signed quantity. [None] at exactly zero, where there is no direction. *)
val of_signed : float -> t option

val opposite : t -> t

val to_string : t -> string

val equal : t -> t -> bool
