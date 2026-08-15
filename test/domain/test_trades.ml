open Algostream_domain_trades

let make_trade ?(id = "trade_001") ?(qty = 100.0) ?(price = 150.0) ?(commission = 1.50)
  ?(side = `Buy) ?(execution_type = Trade.Taker) () =
  Trade.create_trade ~id ~order_id:"order_001" ~symbol:"AAPL" ~side ~quantity:qty ~price
    ~execution_type ~commission ~commission_asset:"USD" ~exchange:"NASDAQ" ()


let test_create_trade () =
  let trade = make_trade () in
    Alcotest.(check string) "id" "trade_001" trade.id ;
    Alcotest.(check string) "symbol" "AAPL" trade.symbol ;
    Alcotest.(check (float 1e-9)) "quantity" 100.0 trade.quantity ;
    Alcotest.(check (float 1e-9)) "price" 150.0 trade.price ;
    Alcotest.(check bool) "is_buy" true (Trade.is_buy trade)


let test_trade_calculations () =
  let trade = make_trade () in
    Alcotest.(check (float 1e-9)) "gross_value" 15000.0 (Trade.gross_value trade) ;
    Alcotest.(check (float 1e-9)) "net_value" 14998.50 (Trade.net_value trade) ;
    Alcotest.(check (float 1e-9)) "effective_price" 150.015 (Trade.effective_price trade)


let test_trade_aggregation () =
  let trade1 = make_trade ~id:"trade_001" ~qty:100.0 ~price:150.0 ~commission:1.50 () in
  let trade2 =
    make_trade ~id:"trade_002" ~qty:50.0 ~price:152.0 ~commission:0.75 ~execution_type:Trade.Maker
      () in
    match Trade.Trade_aggregation.aggregate_trades [ trade1; trade2 ] with
    | None -> Alcotest.fail "Aggregation should succeed"
    | Some agg ->
      Alcotest.(check string) "symbol" "AAPL" agg.symbol ;
      Alcotest.(check (float 1e-9)) "total_quantity" 150.0 agg.total_quantity ;
      Alcotest.(check int) "trade_count" 2 agg.trade_count ;
      Alcotest.(check (float 1e-9)) "total_commission" 2.25 agg.total_commission


let suite =
  [
    Alcotest.test_case "create" `Quick test_create_trade;
    Alcotest.test_case "calculations" `Quick test_trade_calculations;
    Alcotest.test_case "aggregation" `Quick test_trade_aggregation;
  ]
