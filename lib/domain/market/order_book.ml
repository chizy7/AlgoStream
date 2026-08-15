open Base
module Timestamp = Algostream_domain_common.Timestamp

module Price_level = struct
  type t = {
    price : float;
    size : float;
    orders : int;
  }
  [@@deriving sexp, compare]

  let create ~price ~size ~orders = { price; size; orders }

  let total_value t = t.price *. t.size

  let average_order_size t = if Int.(t.orders = 0) then 0.0 else t.size /. Float.of_int t.orders
end

type side =
  | Bid
  | Ask
[@@deriving sexp, compare]

type order_book = {
  symbol : string;
  timestamp : Timestamp.t;
  sequence : int64;
  bids : Price_level.t array;
  asks : Price_level.t array;
}
[@@deriving sexp, compare]

let create_order_book ~symbol ~timestamp ~sequence ~bids ~asks =
  let sorted_bids =
    Array.sorted_copy bids ~compare:(fun a b ->
      Float.compare b.Price_level.price a.Price_level.price) in
  let sorted_asks =
    Array.sorted_copy asks ~compare:(fun a b ->
      Float.compare a.Price_level.price b.Price_level.price) in
    { symbol; timestamp; sequence; bids = sorted_bids; asks = sorted_asks }


let best_bid order_book = if Array.is_empty order_book.bids then None else Some order_book.bids.(0)

let best_ask order_book = if Array.is_empty order_book.asks then None else Some order_book.asks.(0)

let spread order_book =
  match (best_bid order_book, best_ask order_book) with
  | Some bid, Some ask -> Some (ask.price -. bid.price)
  | _ -> None


let mid_price order_book =
  match (best_bid order_book, best_ask order_book) with
  | Some bid, Some ask -> Some ((bid.price +. ask.price) /. 2.0)
  | _ -> None


let spread_percentage order_book =
  match (spread order_book, mid_price order_book) with
  | Some s, Some mid when Float.(mid > 0.0) -> Some (s /. mid *. 100.0)
  | _ -> None


let total_bid_volume order_book =
  Array.fold order_book.bids ~init:0.0 ~f:(fun acc level -> acc +. level.size)


let total_ask_volume order_book =
  Array.fold order_book.asks ~init:0.0 ~f:(fun acc level -> acc +. level.size)


let imbalance order_book =
  let bid_vol = total_bid_volume order_book in
  let ask_vol = total_ask_volume order_book in
  let total_vol = bid_vol +. ask_vol in
    if Float.(total_vol = 0.0) then 0.0 else (bid_vol -. ask_vol) /. total_vol


let depth_at_price order_book ~side ~price =
  let levels = match side with Bid -> order_book.bids | Ask -> order_book.asks in
  let rec accumulate_size i acc =
    if i >= Array.length levels then acc
    else
      let level = levels.(i) in
        match side with
        | Bid when Float.(level.price >= price) -> accumulate_size (i + 1) (acc +. level.size)
        | Ask when Float.(level.price <= price) -> accumulate_size (i + 1) (acc +. level.size)
        | _ -> acc in
    accumulate_size 0 0.0


let weighted_mid_price order_book =
  match (best_bid order_book, best_ask order_book) with
  | Some bid, Some ask ->
    let total_size = bid.size +. ask.size in
      if Float.(total_size = 0.0) then None
      else Some (((bid.price *. ask.size) +. (ask.price *. bid.size)) /. total_size)
  | _ -> None


let is_valid_order_book order_book =
  let bids_valid =
    Array.for_all order_book.bids ~f:(fun level ->
      Float.(level.price > 0.0 && level.size > 0.0) && level.orders >= 0) in
  let asks_valid =
    Array.for_all order_book.asks ~f:(fun level ->
      Float.(level.price > 0.0 && level.size > 0.0) && level.orders >= 0) in
  let spread_valid =
    match (best_bid order_book, best_ask order_book) with
    | Some bid, Some ask -> Float.(ask.price >= bid.price)
    | _ -> true in
    bids_valid && asks_valid && spread_valid
