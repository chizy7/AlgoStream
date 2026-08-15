module Order = Algostream_domain_orders.Order

type urgency =
  | Passive
  | Normal
  | Aggressive

type intent = {
  symbol : string;
  side : Side.t;
  quantity : float;
  order_type : Order.order_type;
  time_in_force : Order.time_in_force;
  client_order_id : string;
  strategy_id : string;
  urgency : urgency;
  tag : string;
}

type t =
  | Submit of intent
  | Cancel of string
  | Replace of {
      client_order_id : string;
      new_quantity : float option;
      new_price : float option;
    }
  | Set_timer of {
      ts_ns : int64;
      tag : string;
    }
  | Log of string

let submit ~symbol ~side ~quantity ~order_type ?(time_in_force = Order.Good_till_cancel)
  ?(urgency = Normal) ?(tag = "") ~client_order_id ~strategy_id () =
  (* A zero-or-negative size is always a sizing bug upstream. Failing loudly beats emitting an order
     the fill engine will silently ignore. *)
  if quantity <= 0.0 then
    invalid_arg
      (Printf.sprintf "Action.submit: quantity must be positive (got %g for %s %s)" quantity symbol
         (Side.to_string side)) ;
  Submit
    {
      symbol;
      side;
      quantity;
      order_type;
      time_in_force;
      client_order_id;
      strategy_id;
      urgency;
      tag;
    }


let urgency_to_string = function
  | Passive -> "passive"
  | Normal -> "normal"
  | Aggressive -> "aggressive"


let order_type_to_string = function
  | Order.Market -> "market"
  | Order.Limit p -> Printf.sprintf "limit@%g" p
  | Order.Stop p -> Printf.sprintf "stop@%g" p
  | Order.Stop_limit { stop_price; limit_price } ->
    Printf.sprintf "stop_limit@%g/%g" stop_price limit_price
  | Order.Iceberg { display_size; total_size } ->
    Printf.sprintf "iceberg %g/%g" display_size total_size


let to_string = function
  | Submit i ->
    Printf.sprintf "Submit %s %s %g %s [%s] %s" i.symbol (Side.to_string i.side) i.quantity
      (order_type_to_string i.order_type)
      (urgency_to_string i.urgency) i.client_order_id
  | Cancel id -> Printf.sprintf "Cancel %s" id
  | Replace r -> Printf.sprintf "Replace %s" r.client_order_id
  | Set_timer t -> Printf.sprintf "SetTimer %s @ %Ld" t.tag t.ts_ns
  | Log s -> Printf.sprintf "Log %s" s
