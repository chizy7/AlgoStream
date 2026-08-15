(** Smart order routing across multiple typed {!Venue.t} snapshots.

    Pure-function API: [route] takes an order and a list of [venue_snapshot] (best bid/ask + depth +
    monthly_volume per venue) and returns a [routing_decision] that the caller then turns into one
    or more bus [Order_request] events. No bus subscription, no state, no submission — testable
    end-to-end as data in / data out. *)

module Order = Algostream_domain_orders.Order

type venue_snapshot = {
  venue : Venue.t;
  best_bid : float;
  best_ask : float;
  bid_depth : float;  (** cumulative shares available at or near the best bid *)
  ask_depth : float;
  monthly_volume : float;  (** caller's trailing 30-day volume on this venue *)
}

type routing_strategy =
  | Cheapest_venue  (** single-venue: lowest effective taker fee among eligible venues *)
  | Best_price  (** single-venue: tightest price for the order's side *)
  | Smart_split
    (** split across venues sorted by effective cost; bottom-up until quantity is met *)

type allocation = {
  venue_name : string;
  quantity : float;
  expected_price : float;
  expected_fee_bps : float;
}

type routing_decision = {
  strategy : routing_strategy;
  allocations : allocation list;
  expected_avg_price : float;
  expected_cost_bps : float;
  unallocated : float;  (** > 0 when total depth across eligible venues < order quantity *)
  rationale : string;
}

val route :
  order:Order.order ->
  venues:venue_snapshot list ->
  ?strategy:routing_strategy ->
  unit ->
  routing_decision
