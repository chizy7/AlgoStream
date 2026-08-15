open Base
open Algostream_domain_portfolio

let test_create_portfolio () =
  let portfolio = Portfolio.create_portfolio ~account_id:"test123" ~initial_capital:100000.0 () in
    Alcotest.(check string) "account_id" "test123" portfolio.account_id ;
    Alcotest.(check (float 1e-9)) "cash_balance" 100000.0 portfolio.cash_balance ;
    Alcotest.(check (float 1e-9)) "initial_capital" 100000.0 portfolio.initial_capital ;
    Alcotest.(check bool) "no positions" true (Map.Poly.is_empty portfolio.positions)


let test_add_trade () =
  let portfolio = Portfolio.create_portfolio ~account_id:"test123" ~initial_capital:100000.0 () in
  let updated =
    Portfolio.add_trade portfolio ~symbol:"AAPL" ~trade_quantity:100.0 ~trade_price:150.0
      ~commission:1.0 () in
    match Portfolio.get_position updated ~symbol:"AAPL" with
    | None -> Alcotest.fail "Position should exist"
    | Some pos ->
      Alcotest.(check (float 1e-9)) "qty" 100.0 pos.quantity ;
      Alcotest.(check (float 1e-9)) "avg_price" 150.0 pos.average_price ;
      Alcotest.(check (float 1e-9)) "cash_balance" (100000.0 -. 15000.0 -. 1.0) updated.cash_balance


let test_portfolio_metrics () =
  let portfolio = Portfolio.create_portfolio ~account_id:"test123" ~initial_capital:100000.0 () in
  let portfolio =
    Portfolio.add_trade portfolio ~symbol:"AAPL" ~trade_quantity:100.0 ~trade_price:150.0
      ~commission:1.0 () in
  let portfolio =
    Portfolio.update_position_prices portfolio
      ~price_updates:(Map.Poly.of_alist_exn [ ("AAPL", 155.0) ]) in
    Alcotest.(check (float 1e-9)) "market_value" 15500.0 (Portfolio.total_market_value portfolio) ;
    Alcotest.(check (float 1e-9)) "nav" (84999.0 +. 15500.0) (Portfolio.net_asset_value portfolio)


let suite =
  [
    Alcotest.test_case "create" `Quick test_create_portfolio;
    Alcotest.test_case "add_trade" `Quick test_add_trade;
    Alcotest.test_case "metrics" `Quick test_portfolio_metrics;
  ]
