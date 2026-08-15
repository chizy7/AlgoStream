open Base
module Timestamp = Algostream_domain_common.Timestamp

type order_side =
  | Buy
  | Sell
[@@deriving sexp, compare, hash]

type order_type =
  | Market
  | Limit of float
  | Stop of float
  | Stop_limit of {
      stop_price : float;
      limit_price : float;
    }
  | Iceberg of {
      display_size : float;
      total_size : float;
    }
[@@deriving sexp, compare]

type time_in_force =
  | Good_till_cancel
  | Immediate_or_cancel
  | Fill_or_kill
  | Good_till_date of Timestamp.t
[@@deriving sexp, compare]

type order_status =
  | Pending
  | Open
  | Partially_filled of { filled_quantity : float }
  | Filled
  | Cancelled
  | Rejected of string
  | Expired
[@@deriving sexp, compare]

type order = {
  id : string;
  client_order_id : string;
  symbol : string;
  side : order_side;
  order_type : order_type;
  quantity : float;
  time_in_force : time_in_force;
  status : order_status;
  created_at : Timestamp.t;
  updated_at : Timestamp.t;
  filled_quantity : float;
  average_fill_price : float option;
  commission : float;
  exchange : string;
  strategy_id : string option;
}
[@@deriving sexp, compare]

(* Event-time hook — see the note in [Position]. The backtest engine stamps orders with the event
   time at which the strategy emitted the intent, which is what [Execution_quality.analyze] needs
   for its decision-to-first-fill latency to mean anything under replay. *)
let stamp = function Some t -> t | None -> Timestamp.now ()

let create_order ?ts ~id ~client_order_id ~symbol ~side ~order_type ~quantity ~time_in_force
  ~exchange ?strategy_id () =
  let now = stamp ts in
    {
      id;
      client_order_id;
      symbol;
      side;
      order_type;
      quantity;
      time_in_force;
      status = Pending;
      created_at = now;
      updated_at = now;
      filled_quantity = 0.0;
      average_fill_price = None;
      commission = 0.0;
      exchange;
      strategy_id;
    }


let create_market_order ?ts ~id ~client_order_id ~symbol ~side ~quantity ~exchange ?strategy_id () =
  create_order ?ts ~id ~client_order_id ~symbol ~side ~order_type:Market ~quantity
    ~time_in_force:Immediate_or_cancel ~exchange ?strategy_id ()


let create_limit_order ?ts ~id ~client_order_id ~symbol ~side ~quantity ~price ~exchange
  ?strategy_id () =
  create_order ?ts ~id ~client_order_id ~symbol ~side ~order_type:(Limit price) ~quantity
    ~time_in_force:Good_till_cancel ~exchange ?strategy_id ()


let remaining_quantity order = order.quantity -. order.filled_quantity

let is_open order = match order.status with Open | Partially_filled _ -> true | _ -> false

let is_filled order = match order.status with Filled -> true | _ -> false

let is_pending order = match order.status with Pending -> true | _ -> false

let is_cancelled order = match order.status with Cancelled -> true | _ -> false

let is_rejected order = match order.status with Rejected _ -> true | _ -> false

let fill_percentage order =
  if Float.(order.quantity = 0.0) then 0.0 else order.filled_quantity /. order.quantity *. 100.0


let update_status ?ts order new_status = { order with status = new_status; updated_at = stamp ts }

let add_fill ?ts order ~fill_quantity ~fill_price =
  let new_filled = order.filled_quantity +. fill_quantity in
  let new_avg_price =
    match order.average_fill_price with
    | None -> Some fill_price
    | Some avg_price ->
      let total_value = (order.filled_quantity *. avg_price) +. (fill_quantity *. fill_price) in
        Some (total_value /. new_filled) in
  let new_status =
    if Float.(new_filled = order.quantity) then Filled
    else Partially_filled { filled_quantity = new_filled } in
    {
      order with
      filled_quantity = new_filled;
      average_fill_price = new_avg_price;
      status = new_status;
      updated_at = stamp ts;
    }


let get_limit_price order =
  match order.order_type with
  | Limit price -> Some price
  | Stop_limit { limit_price; _ } -> Some limit_price
  | _ -> None


let get_stop_price order =
  match order.order_type with
  | Stop price -> Some price
  | Stop_limit { stop_price; _ } -> Some stop_price
  | _ -> None


let order_value order =
  match get_limit_price order with Some price -> price *. order.quantity | None -> 0.0


let order_side_to_string = function Buy -> "BUY" | Sell -> "SELL"

let order_type_to_string = function
  | Market -> "MARKET"
  | Limit price -> Printf.sprintf "LIMIT@%.2f" price
  | Stop price -> Printf.sprintf "STOP@%.2f" price
  | Stop_limit { stop_price; limit_price } ->
    Printf.sprintf "STOP_LIMIT@%.2f/%.2f" stop_price limit_price
  | Iceberg { display_size; total_size } ->
    Printf.sprintf "ICEBERG@%.2f/%.2f" display_size total_size
