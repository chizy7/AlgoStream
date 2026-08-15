type t = Algostream_domain_orders.Order.order_side =
  | Buy
  | Sell

let of_trade_side = function `Buy -> Buy | `Sell -> Sell

let to_trade_side = function Buy -> `Buy | Sell -> `Sell

let sign = function Buy -> 1.0 | Sell -> -1.0

(* [qty] is taken as a magnitude: the side argument is authoritative, so passing a already-negative
   quantity for a Sell cannot double-negate into a buy. *)
let signed side ~qty = sign side *. Float.abs qty

let of_signed q = if q > 0.0 then Some Buy else if q < 0.0 then Some Sell else None

let opposite = function Buy -> Sell | Sell -> Buy

let to_string = function Buy -> "buy" | Sell -> "sell"

let equal a b = match (a, b) with Buy, Buy | Sell, Sell -> true | _ -> false
