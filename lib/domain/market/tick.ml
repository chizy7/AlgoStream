open Base
module Timestamp = Algostream_domain_common.Timestamp

type tick = {
  symbol : string;
  timestamp : Timestamp.t;
  bid_price : float;
  ask_price : float;
  bid_size : float;
  ask_size : float;
  last_price : float option;
  last_size : float option;
  volume : float;
  sequence : int64;
}
[@@deriving sexp, compare]

type trade_tick = {
  symbol : string;
  timestamp : Timestamp.t;
  price : float;
  size : float;
  side : [ `Buy | `Sell ];
  trade_id : string;
  sequence : int64;
}
[@@deriving sexp, compare]

let create_tick ~symbol ~timestamp ~bid_price ~ask_price ~bid_size ~ask_size ?last_price ?last_size
  ~volume ~sequence () =
  {
    symbol;
    timestamp;
    bid_price;
    ask_price;
    bid_size;
    ask_size;
    last_price;
    last_size;
    volume;
    sequence;
  }


let create_trade_tick ~symbol ~timestamp ~price ~size ~side ~trade_id ~sequence =
  { symbol; timestamp; price; size; side; trade_id; sequence }


let spread tick = tick.ask_price -. tick.bid_price

let mid_price tick = (tick.bid_price +. tick.ask_price) /. 2.0

let is_valid_tick tick =
  Float.(
    tick.bid_price > 0.0 && tick.ask_price > 0.0 && tick.bid_size > 0.0 && tick.ask_size > 0.0
    && tick.ask_price >= tick.bid_price)


let tick_age tick ~current_time = Timestamp.diff current_time tick.timestamp

let is_stale tick ~current_time ~max_age = Float.(tick_age tick ~current_time > max_age)
