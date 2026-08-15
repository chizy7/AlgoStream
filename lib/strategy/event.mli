(** What a strategy observes.

    Deliberately {b not} [Event_bus.Event.payload]. The bus type carries transport concerns
    (sequence ids, priority bands, [Raw of bytes]) that a strategy has no business seeing, and the
    bus delivery path is asynchronous and only eventually consistent — unusable for a reproducible
    backtest. The backtest engine and a future live runner both translate into this type, which is
    what lets one [Strategy.S] serve both.

    Every constructor carries [ts_ns] event time. Nothing here is derived from a clock. *)

module Bar = Algostream_time_series.Bar
module Order = Algostream_domain_orders.Order
module Order_book = Algostream_domain_market.Order_book
module Trade = Algostream_domain_trades.Trade

(** A completed execution, reported back to the strategy after the inbound latency delay. *)
type fill = {
  ts_ns : int64;
  order_id : string;
  client_order_id : string;
  symbol : string;
  side : Side.t;
  quantity : float;  (** always positive; direction is in [side] *)
  price : float;
  commission : float;
  liquidity : Trade.execution_type;  (** [Maker] / [Taker] — drives which fee tier was charged *)
  venue : string;
}

type order_reason =
  | Accepted
  | Rejected of string
  | Cancelled
  | Expired
  | Partially_filled
  | Filled

type t =
  | Tick of {
      symbol : string;
      ts_ns : int64;
      price : float;
      volume : float;
      bid : float option;
      ask : float option;
    }
  | Bar of Bar.t
  | Book of Order_book.order_book
  | Pair_snapshot of {
      snapshot : Algostream_pairs.Snapshot.t;
      y_symbol : string;
      x_symbol : string;
    }
    (** Emitted by the engine after driving [Pairs.Per_pair] inline. The engine deliberately
        bypasses [Pairs.Processor] — its Domain + SPSC queue + bus subscription are
        eventual-consistency machinery that would make a backtest irreproducible.

        [Pair_id.t] holds {i canonical} symbols ([BTC/USDT]), but orders must be placed against
        {i raw} exchange symbols ([BTCUSDT]). The engine configured the pair and therefore knows the
        mapping, so it carries it here rather than making every strategy re-derive it. *)
  | Fill of fill
  | Order_update of {
      order : Order.order;
      ts_ns : int64;
      reason : order_reason;
    }
  | Timer of {
      ts_ns : int64;
      tag : string;
    }

(** Event time of any event — the strategy's only legitimate source of "now". *)
val ts_ns : t -> int64

(** The symbol an event concerns, where it concerns exactly one. [Pair_snapshot] and [Timer] return
    [None]. *)
val symbol : t -> string option

val reason_to_string : order_reason -> string

val to_string : t -> string
