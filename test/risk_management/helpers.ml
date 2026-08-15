open Base
module Portfolio = Algostream_domain_portfolio.Portfolio
module Position = Algostream_domain_portfolio.Position
module Order = Algostream_domain_orders.Order

let make_portfolio ?(account_id = "acct") ?(initial_capital = 100_000.0) () =
  Portfolio.create_portfolio ~account_id ~initial_capital ()


(* Create a portfolio with explicit positions for testing. Sets cash so the NAV equals [nav]. *)
let portfolio_with_positions ?(nav = 100_000.0) ~positions () =
  let initial = nav in
  let p = make_portfolio ~initial_capital:initial () in
  let total_position_value =
    List.fold positions ~init:0.0 ~f:(fun acc (_, q, price) -> acc +. (q *. price)) in
  let cash = initial -. total_position_value in
  let positions_map =
    List.fold positions ~init:Map.Poly.empty ~f:(fun acc (symbol, quantity, price) ->
      let pos = Position.create_position ~symbol () in
      let pos = Position.add_trade pos ~trade_quantity:quantity ~trade_price:price ~commission:0.0 in
      let pos = Position.update_last_price pos ~new_price:price in
        Map.Poly.set acc ~key:symbol ~data:pos) in
    { p with positions = positions_map; cash_balance = cash }


let make_order ?(quantity = 100.0) ?(side = Order.Buy) ?(symbol = "BTCUSDT") () =
  Order.create_order ~id:"o" ~client_order_id:"c" ~symbol ~side ~order_type:Order.Market ~quantity
    ~time_in_force:Order.Immediate_or_cancel ~exchange:"test" ()


let normal_sample rng =
  let u1 = Float.max 1e-12 (Random.State.float rng 1.0) in
  let u2 = Random.State.float rng 1.0 in
    Float.sqrt (-2.0 *. Float.log u1) *. Float.cos (2.0 *. Float.pi *. u2)


let normal_returns ~n ~mean ~sd ~seed =
  let rng = Random.State.make [| seed |] in
    Array.init n ~f:(fun _ -> mean +. (sd *. normal_sample rng))
