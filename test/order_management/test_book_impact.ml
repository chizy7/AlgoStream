open Algostream_order_management
module Order = Algostream_domain_orders.Order

let test_walk_buy_through_levels () =
  (* asks: [(100.1, 100), (100.2, 200), (100.3, 500)]; mid ~ 100.05 Buy 500: 100@100.1 + 200@100.2 +
     200@100.3 = 10010 + 20040 + 20060 = 50110 avg = 50110 / 500 = 100.22 *)
  let book =
    Helpers.make_book
      ~bids:[| Helpers.make_level ~price:100.0 ~size:100.0 |]
      ~asks:
        [|
          Helpers.make_level ~price:100.1 ~size:100.0;
          Helpers.make_level ~price:100.2 ~size:200.0;
          Helpers.make_level ~price:100.3 ~size:500.0;
        |]
      () in
  let e = Book_impact.estimate_from_book ~side:Order.Buy ~quantity:500.0 ~book in
    Alcotest.(check (float 1e-9)) "qty filled = 500" 500.0 e.quantity_filled ;
    Alcotest.(check (float 1e-6)) "avg = 100.22" 100.22 e.avg_fill_price ;
    Alcotest.(check (float 1e-9)) "worst = 100.3" 100.3 e.worst_fill_price ;
    Alcotest.(check int) "3 levels consumed" 3 e.levels_consumed ;
    Alcotest.(check (float 1e-9)) "no unfilled" 0.0 e.unfilled_quantity ;
    Alcotest.(check bool) "slippage_bps positive (buy walking up)" true (e.slippage_bps > 0.0)


let test_unfilled_when_thin () =
  let book =
    Helpers.make_book
      ~bids:[| Helpers.make_level ~price:100.0 ~size:100.0 |]
      ~asks:[| Helpers.make_level ~price:100.1 ~size:50.0 |]
      () in
  let e = Book_impact.estimate_from_book ~side:Order.Buy ~quantity:200.0 ~book in
    Alcotest.(check (float 1e-9)) "filled = 50" 50.0 e.quantity_filled ;
    Alcotest.(check (float 1e-9)) "unfilled = 150" 150.0 e.unfilled_quantity


let test_sell_slippage_signed () =
  (* bids: [(99.9, 100), (99.8, 200)]; ask: 100.1; mid ~ 100.0 Sell 100 → fills at 99.9 →
     slippage_bps = -(99.9 - 100)/100 *1e4 = +10 bps adverse *)
  let book =
    Helpers.make_book
      ~bids:
        [| Helpers.make_level ~price:99.9 ~size:100.0; Helpers.make_level ~price:99.8 ~size:200.0 |]
      ~asks:[| Helpers.make_level ~price:100.1 ~size:100.0 |]
      () in
  let e = Book_impact.estimate_from_book ~side:Order.Sell ~quantity:100.0 ~book in
    Alcotest.(check bool) "sell slippage positive (adverse)" true (e.slippage_bps > 0.0)


let test_permanent_impact_monotonic () =
  let small =
    Book_impact.permanent_impact ~quantity:1000.0 ~daily_volume:1_000_000.0 ~daily_vol:0.02 () in
  let large =
    Book_impact.permanent_impact ~quantity:100_000.0 ~daily_volume:1_000_000.0 ~daily_vol:0.02 ()
  in
    Alcotest.(check bool) "larger order → larger impact" true (large.impact_bps > small.impact_bps) ;
    Alcotest.(check bool) "small participation < 1.0" true (small.participation_rate < 1.0)


let test_permanent_impact_known_value () =
  (* gamma=0.5, sigma=0.02, Q/V=0.01 → impact_bps = 0.5 * 0.02 * sqrt(0.01) * 1e4 = 10 *)
  let p =
    Book_impact.permanent_impact ~quantity:10_000.0 ~daily_volume:1_000_000.0 ~daily_vol:0.02 ()
  in
    Alcotest.(check (float 1e-6)) "known impact = 10 bps" 10.0 p.impact_bps


let test_permanent_impact_caps_participation () =
  let p =
    Book_impact.permanent_impact ~quantity:5_000_000.0 ~daily_volume:1_000_000.0 ~daily_vol:0.02 ()
  in
    Alcotest.(check (float 1e-9)) "participation capped at 1.0" 1.0 p.participation_rate


let suite =
  [
    Alcotest.test_case "walk_buy_through_levels" `Quick test_walk_buy_through_levels;
    Alcotest.test_case "unfilled_when_thin" `Quick test_unfilled_when_thin;
    Alcotest.test_case "sell_slippage_signed" `Quick test_sell_slippage_signed;
    Alcotest.test_case "permanent_impact_monotonic" `Quick test_permanent_impact_monotonic;
    Alcotest.test_case "permanent_impact_known_value" `Quick test_permanent_impact_known_value;
    Alcotest.test_case "permanent_impact_caps_participation" `Quick
      test_permanent_impact_caps_participation;
  ]
