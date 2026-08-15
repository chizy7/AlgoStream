module Portfolio = Algostream_domain_portfolio.Portfolio
module Order = Algostream_domain_orders.Order
module Order_book = Algostream_domain_market.Order_book

type t = {
  ts_ns : int64;
  seq : int;
  portfolio : Portfolio.portfolio;
  nav : float;
  working_orders : Order.order list;
  position : string -> float;
  last_price : string -> float option;
  quote : string -> (float * float) option;
  book : string -> Order_book.order_book option;
  risk : Algostream_risk_management.Risk_snapshot.t option;
}

let mid t symbol =
  match t.quote symbol with
  | Some (bid, ask) when bid > 0.0 && ask > 0.0 -> Some ((bid +. ask) /. 2.0)
  (* A one-sided book is common on thin instruments; fall back rather than report nothing. *)
  | _ -> t.last_price symbol


let half_spread_bps t symbol =
  match t.quote symbol with
  | Some (bid, ask) when bid > 0.0 && ask > bid ->
    let m = (bid +. ask) /. 2.0 in
      if m <= 0.0 then None else Some ((ask -. bid) /. 2.0 /. m *. 10_000.0)
  | _ -> None


let has_position t symbol = Float.abs (t.position symbol) > 1e-12

let working_for t symbol =
  List.filter (fun (o : Order.order) -> String.equal o.Order.symbol symbol) t.working_orders
