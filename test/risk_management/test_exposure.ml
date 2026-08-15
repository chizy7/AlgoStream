open Algostream_risk_management

let test_three_position_portfolio () =
  let p =
    Helpers.portfolio_with_positions ~nav:100_000.0
      ~positions:
        [
          ("BTCUSDT", 10.0, 1000.0);
          (* $10k long *)
          ("ETHUSDT", 20.0, 500.0);
          (* $10k long *)
          ("SOLUSDT", -50.0, 200.0);
          (* $10k short *)
        ]
      () in
  let e = Exposure.compute ~portfolio:p () in
    Alcotest.(check (float 1.0)) "gross = 30k" 30_000.0 e.gross_exposure ;
    Alcotest.(check (float 1.0)) "net = 10k (20k long - 10k short)" 10_000.0 e.net_exposure ;
    Alcotest.(check int) "3 positions" 3 e.n_positions ;
    Alcotest.(check (float 1e-6))
      "largest pos pct = 10% (each is 10k of 100k)" 0.1 e.largest_position_pct ;
    Alcotest.(check int) "per_symbol has 3 entries" 3 (List.length e.per_symbol)


let test_per_symbol_sorted () =
  let p =
    Helpers.portfolio_with_positions ~nav:100_000.0
      ~positions:
        [
          ("SMALL", 10.0, 100.0);
          (* $1k *)
          ("BIG", 50.0, 1000.0);
          (* $50k *)
          ("MID", 10.0, 500.0) (* $5k *);
        ]
      () in
  let e = Exposure.compute ~portfolio:p () in
    match e.per_symbol with
    | first :: second :: third :: _ ->
      Alcotest.(check string) "biggest first" "BIG" first.symbol ;
      Alcotest.(check string) "mid second" "MID" second.symbol ;
      Alcotest.(check string) "small third" "SMALL" third.symbol
    | _ -> Alcotest.fail "expected 3 entries"


let test_asset_class_lookup () =
  let p =
    Helpers.portfolio_with_positions ~nav:100_000.0
      ~positions:[ ("BTC", 1.0, 50000.0); ("AAPL", 100.0, 150.0) ]
      () in
  let lookup = function "BTC" -> "crypto" | _ -> "equity" in
  let e = Exposure.compute ~portfolio:p ~asset_class_lookup:lookup () in
    Alcotest.(check int) "2 asset classes" 2 (List.length e.per_asset_class)


let suite =
  [
    Alcotest.test_case "three_position_portfolio" `Quick test_three_position_portfolio;
    Alcotest.test_case "per_symbol_sorted" `Quick test_per_symbol_sorted;
    Alcotest.test_case "asset_class_lookup" `Quick test_asset_class_lookup;
  ]
