(** Order book impact estimation.

    Two flavors:
    - {!estimate_from_book}: walk the local order book to estimate the actual fill (avg price, worst
      price, slippage vs mid, unfilled quantity if the book is too thin).
    - {!permanent_impact}: Almgren-style square-root model
      [Δp/p ≈ γ · σ · √(quantity / daily_volume)] for cross-day participation rates. *)

module Order = Algostream_domain_orders.Order
module Order_book = Algostream_domain_market.Order_book

type estimate = {
  avg_fill_price : float;
  worst_fill_price : float;
  slippage_bps : float;  (** vs mid, signed positive when adverse to the order side *)
  quantity_filled : float;
  levels_consumed : int;
  unfilled_quantity : float;
}

val estimate_from_book :
  side:Order.order_side -> quantity:float -> book:Order_book.order_book -> estimate

type permanent_impact = {
  impact_bps : float;
  participation_rate : float;
}

(** [permanent_impact] uses the standard literature [gamma = 0.5] (Almgren et al. 2005, "Direct
    Estimation of Equity Market Impact"). Participation rate is capped at 1.0; an order larger than
    [daily_volume] is not practically executable in a single day. *)
val permanent_impact :
  quantity:float ->
  daily_volume:float ->
  daily_vol:float ->
  ?gamma:float ->
  unit ->
  permanent_impact
