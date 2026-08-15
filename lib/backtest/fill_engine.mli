(** Order matching against historical data.

    This is where the order types acquire behaviour. Nothing else in the tree interpreted
    [time_in_force], evaluated a [Stop] trigger, or exposed only an [Iceberg]'s display slice — the
    constructors existed in [Order.order_type] and were pattern-matched nowhere.

    {2 Maker fills}

    Passive fills are simulated with an explicit {b queue position}. When a resting limit order
    arrives at the venue, its [queue_ahead] is seeded from [Order_book.depth_at_price ~side ~price]
    — the liquidity already resting at or better than our price. Every subsequent tape print at or
    through that price decrements it, and we only begin filling once it reaches zero.

    That model is approximate in a specific, documented way: [depth_at_price] is cumulative
    {i at or better}, so it counts better-priced orders that are not literally in our queue. Since
    those orders do fill ahead of us anyway, the estimate is conservative in the right direction —
    it makes maker fills harder, not easier. What it cannot capture is order-by-order priority
    within a level, which would need L3 data the ingestion layer does not capture.

    An iceberg that refreshes a slice goes to the {b back} of the queue — [queue_ahead] is reseeded
    from current depth. That is real venue behaviour and it is the main reason naive iceberg
    simulation overstates fill rates.

    {2 Ordering}

    A pass over one market record proceeds: not-yet-arrived orders are skipped (latency), stops are
    evaluated, marketable orders cross, then resting orders advance their queue. TIF is applied
    last, because IOC and FOK are decisions about what to do with whatever did {i not} fill. *)

module Order = Algostream_domain_orders.Order
module Trade = Algostream_domain_trades.Trade
module Execution_quality = Algostream_order_management.Execution_quality
module Action = Algostream_strategy.Action
module Event = Algostream_strategy.Event
module Rng = Algostream_rng.Rng

type maker_fill_model =
  | Queue_position
    (** the default; seeds [queue_ahead] from book depth and drains it on tape prints *)
  | Touch_cross
    (** fill when the market trades through our price, ignoring queue. More optimistic, much
        cheaper, adequate when the strategy is not queue-sensitive *)
  | Optimistic
    (** fill the moment the touch reaches our price. An upper bound on achievable passive
        performance; useful for bracketing, dishonest as a headline *)

type stop_trigger_ref =
  | Trigger_last
  | Trigger_mid
  | Trigger_touch  (** bid for sell-stops, ask for buy-stops — the conservative choice *)

type config = {
  slippage : Slippage.model;
  latency : Latency.t;
  maker_fill : maker_fill_model;
  stop_trigger : stop_trigger_ref;
  allow_partial : bool;  (** when false, a partially fillable order fills fully or not at all *)
}

val default_config : config

type t

val create : config:config -> cost:Cost_model.t -> rng:Rng.t -> t

(** Accept an intent. Returns the [Order.order] the engine created, stamped with [now_ns] as its
    decision time; it becomes eligible to match only after the outbound latency has elapsed. *)
val admit :
  t -> now_ns:int64 -> Action.intent -> order_id:string -> decision_price:float -> Order.order

(** Advance matching by one market record. Returns the fills that occurred and any order status
    changes (expiry, IOC/FOK cancellation). Both are in event time. *)
val on_market :
  t ->
  now_ns:int64 ->
  Data_source.record ->
  ctx:Slippage.market_ctx ->
  Event.fill list * Event.t list

(** Request cancellation. Takes effect after the cancel latency, so a cancel can lose a race with a
    fill — which is exactly what happens on a real venue. *)
val cancel : t -> now_ns:int64 -> client_order_id:string -> unit

val working_orders : t -> Order.order list

val is_working : t -> client_order_id:string -> bool

(** Cancel everything outstanding; used at end of run. *)
val cancel_all : t -> now_ns:int64 -> Event.t list

(** Post-trade TCA for a completed order, via the existing
    [Order_management.Execution_quality.analyze]. [None] if the order never existed or never filled.
*)
val tca : t -> client_order_id:string -> market_vwap:float -> Execution_quality.report option

type stats = {
  n_admitted : int;
  n_fills : int;
  n_maker_fills : int;
  n_taker_fills : int;
  n_cancelled : int;
  n_expired : int;
  n_fok_killed : int;
  n_ioc_remainder_cancelled : int;
  n_stops_triggered : int;
  unfilled_quantity : float;
}

val stats : t -> stats
