open Base
module Timestamp = Algostream_domain_common.Timestamp

type execution_type =
  | Maker
  | Taker
  | Self_trade
[@@deriving sexp, compare]

type trade = {
  id : string;
  order_id : string;
  symbol : string;
  side : [ `Buy | `Sell ];
  quantity : float;
  price : float;
  timestamp : Timestamp.t;
  execution_type : execution_type;
  commission : float;
  commission_asset : string;
  exchange : string;
  strategy_id : string option;
  counterparty_order_id : string option;
}
[@@deriving sexp, compare]

(* Event-time hook — see the note in [Position]. The backtest fill engine stamps every simulated
   trade with the event time of the fill, so a blotter replays identically. *)
let stamp = function Some t -> t | None -> Timestamp.now ()

let create_trade ?ts ~id ~order_id ~symbol ~side ~quantity ~price ~execution_type ~commission
  ~commission_asset ~exchange ?strategy_id ?counterparty_order_id () =
  {
    id;
    order_id;
    symbol;
    side;
    quantity;
    price;
    timestamp = stamp ts;
    execution_type;
    commission;
    commission_asset;
    exchange;
    strategy_id;
    counterparty_order_id;
  }


let gross_value trade = trade.price *. trade.quantity

let net_value trade = gross_value trade -. trade.commission

let is_buy trade = match trade.side with `Buy -> true | `Sell -> false

let is_sell trade = match trade.side with `Sell -> true | `Buy -> false

let trade_pnl trade ~reference_price =
  let gross = gross_value trade in
    match trade.side with
    | `Buy -> (reference_price *. trade.quantity) -. gross -. trade.commission
    | `Sell -> gross -. (reference_price *. trade.quantity) -. trade.commission


let commission_rate trade =
  let gross = gross_value trade in
    if Float.(gross = 0.0) then 0.0 else trade.commission /. gross *. 100.0


let effective_price trade =
  match trade.side with
  | `Buy -> trade.price +. (trade.commission /. trade.quantity)
  | `Sell -> trade.price -. (trade.commission /. trade.quantity)


module Trade_aggregation = struct
  type aggregated_trades = {
    symbol : string;
    total_quantity : float;
    volume_weighted_price : float;
    total_commission : float;
    trade_count : int;
    first_trade_time : Timestamp.t;
    last_trade_time : Timestamp.t;
  }
  [@@deriving sexp, compare]

  let aggregate_trades (trades : trade list) =
    if List.is_empty trades then None
    else
      let symbol = (List.hd_exn trades).symbol in
      let total_quantity =
        List.fold trades ~init:0.0 ~f:(fun acc (trade : trade) -> acc +. trade.quantity) in
      let total_value =
        List.fold trades ~init:0.0 ~f:(fun acc (trade : trade) -> acc +. gross_value trade) in
      let vwap = if Float.(total_quantity = 0.0) then 0.0 else total_value /. total_quantity in
      let total_commission =
        List.fold trades ~init:0.0 ~f:(fun acc (trade : trade) -> acc +. trade.commission) in
      let trade_count = List.length trades in
      let times = List.map trades ~f:(fun t -> t.timestamp) in
      let first_trade_time = List.min_elt times ~compare:Timestamp.compare |> Option.value_exn in
      let last_trade_time = List.max_elt times ~compare:Timestamp.compare |> Option.value_exn in
        Some
          {
            symbol;
            total_quantity;
            volume_weighted_price = vwap;
            total_commission;
            trade_count;
            first_trade_time;
            last_trade_time;
          }


  let calculate_twap aggregated =
    let duration = Timestamp.diff aggregated.last_trade_time aggregated.first_trade_time in
      if Float.(duration = 0.0) then aggregated.volume_weighted_price
      else
        aggregated.volume_weighted_price (* TWAP calculation would need more detailed time series *)


  type execution_quality = {
    slippage : float;
    implementation_shortfall : float;
    is_favorable : bool;
  }
  [@@deriving sexp]

  let execution_quality trade ~benchmark_price =
    let slippage =
      match trade.side with
      | `Buy -> (trade.price -. benchmark_price) /. benchmark_price
      | `Sell -> (benchmark_price -. trade.price) /. benchmark_price in
    let implementation_shortfall =
      Float.abs slippage +. (trade.commission /. (benchmark_price *. trade.quantity)) in
      {
        slippage = slippage *. 100.0;
        (* as percentage *)
        implementation_shortfall = implementation_shortfall *. 100.0;
        is_favorable = Float.(slippage < 0.0);
      }
end
