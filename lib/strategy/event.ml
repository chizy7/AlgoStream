module Bar = Algostream_time_series.Bar
module Order = Algostream_domain_orders.Order
module Order_book = Algostream_domain_market.Order_book
module Trade = Algostream_domain_trades.Trade
module Timestamp = Algostream_domain_common.Timestamp

type fill = {
  ts_ns : int64;
  order_id : string;
  client_order_id : string;
  symbol : string;
  side : Side.t;
  quantity : float;
  price : float;
  commission : float;
  liquidity : Trade.execution_type;
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

let ts_ns = function
  | Tick t -> t.ts_ns
  | Bar b -> b.Bar.close_ts
  | Book b -> Timestamp.to_ns b.Order_book.timestamp
  | Pair_snapshot p -> p.snapshot.Algostream_pairs.Snapshot.last_event_ts_ns
  | Fill f -> f.ts_ns
  | Order_update o -> o.ts_ns
  | Timer t -> t.ts_ns


let symbol = function
  | Tick t -> Some t.symbol
  | Bar b -> Some b.Bar.symbol
  | Book b -> Some b.Order_book.symbol
  | Fill f -> Some f.symbol
  | Order_update o -> Some o.order.Order.symbol
  | Pair_snapshot _ | Timer _ -> None


let reason_to_string = function
  | Accepted -> "accepted"
  | Rejected r -> "rejected:" ^ r
  | Cancelled -> "cancelled"
  | Expired -> "expired"
  | Partially_filled -> "partially_filled"
  | Filled -> "filled"


let to_string = function
  | Tick t -> Printf.sprintf "Tick %s ts=%Ld px=%g" t.symbol t.ts_ns t.price
  | Bar b ->
    Printf.sprintf "Bar %s [%Ld,%Ld) c=%g" b.Bar.symbol b.Bar.open_ts b.Bar.close_ts b.Bar.close
  | Book b -> Printf.sprintf "Book %s seq=%Ld" b.Order_book.symbol b.Order_book.sequence
  | Pair_snapshot p ->
    Printf.sprintf "PairSnapshot %s/%s z=%g" p.y_symbol p.x_symbol
      p.snapshot.Algostream_pairs.Snapshot.z_score
  | Fill f ->
    Printf.sprintf "Fill %s %s %g @ %g (%s)" f.symbol (Side.to_string f.side) f.quantity f.price
      f.client_order_id
  | Order_update o ->
    Printf.sprintf "OrderUpdate %s %s" o.order.Order.id (reason_to_string o.reason)
  | Timer t -> Printf.sprintf "Timer %s ts=%Ld" t.tag t.ts_ns
