module Order = Algostream_domain_orders.Order

type status = Order.order_status

let is_terminal = function
  | Order.Filled | Order.Cancelled | Order.Rejected _ | Order.Expired -> true
  | Order.Pending | Order.Open | Order.Partially_filled _ -> false


let is_active = function
  | Order.Open | Order.Partially_filled _ -> true
  | Order.Pending | Order.Filled | Order.Cancelled | Order.Rejected _ | Order.Expired -> false


let status_name = function
  | Order.Pending -> "Pending"
  | Order.Open -> "Open"
  | Order.Partially_filled _ -> "Partially_filled"
  | Order.Filled -> "Filled"
  | Order.Cancelled -> "Cancelled"
  | Order.Rejected _ -> "Rejected"
  | Order.Expired -> "Expired"


type transition_error =
  | Invalid_transition of {
      from_ : string;
      to_ : string;
    }
  | Terminal_state of string

let can_transition ~from_ ~to_ =
  match (from_, to_) with
  | Order.Pending, Order.Open | Order.Pending, Order.Rejected _ | Order.Pending, Order.Cancelled ->
    true
  | Order.Open, Order.Partially_filled _
  | Order.Open, Order.Filled
  | Order.Open, Order.Cancelled
  | Order.Open, Order.Rejected _
  | Order.Open, Order.Expired ->
    true
  | Order.Partially_filled _, Order.Partially_filled _
  | Order.Partially_filled _, Order.Filled
  | Order.Partially_filled _, Order.Cancelled
  | Order.Partially_filled _, Order.Expired ->
    true
  | _ -> false


let transition (order : Order.order) ~to_ =
  let from_ = order.status in
    if is_terminal from_ then Error (Terminal_state (status_name from_))
    else if not (can_transition ~from_ ~to_) then
      Error (Invalid_transition { from_ = status_name from_; to_ = status_name to_ })
    else Ok to_
