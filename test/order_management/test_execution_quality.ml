open Algostream_order_management
module Order = Algostream_domain_orders.Order

let make_fill ~ts_ns ~price ~quantity ?(venue = "v") ?(commission = 0.0) () =
  Execution_quality.{ ts_ns; price; quantity; venue; commission }


let test_buy_full_fill_slippage_positive () =
  let order = Helpers.make_order ~side:Order.Buy ~quantity:1000.0 () in
  let fills =
    [
      make_fill ~ts_ns:1_000_000L ~price:100.5 ~quantity:400.0 ();
      make_fill ~ts_ns:2_000_000L ~price:100.6 ~quantity:400.0 ();
      make_fill ~ts_ns:3_000_000L ~price:100.8 ~quantity:200.0 ();
    ] in
  let r =
    Execution_quality.analyze ~order ~decision_price:100.0 ~decision_ts_ns:0L ~fills
      ~market_vwap:100.5 in
    Alcotest.(check (float 1e-9)) "filled_quantity = 1000" 1000.0 r.filled_quantity ;
    Alcotest.(check (float 1e-9)) "fill_rate = 1.0" 1.0 r.fill_rate ;
    (* avg = (400*100.5 + 400*100.6 + 200*100.8) / 1000 = 100.60 *)
    Alcotest.(check (float 1e-6)) "avg fill = 100.6" 100.6 r.avg_fill_price ;
    (* slippage = (100.60 - 100) / 100 * 1e4 = 60 bps *)
    Alcotest.(check (float 1e-6)) "slippage = 60 bps" 60.0 r.slippage_bps ;
    Alcotest.(check bool)
      "time_to_full_fill present" true
      (match r.time_to_full_fill_ns with Some _ -> true | None -> false) ;
    Alcotest.(check string)
      "first_fill_latency_ns = 1ms" "1000000"
      (Int64.to_string r.first_fill_latency_ns)


let test_sell_slippage_signed () =
  let order = Helpers.make_order ~side:Order.Sell ~quantity:100.0 () in
  let fills = [ make_fill ~ts_ns:1_000L ~price:99.5 ~quantity:100.0 () ] in
  let r =
    Execution_quality.analyze ~order ~decision_price:100.0 ~decision_ts_ns:0L ~fills
      ~market_vwap:100.0 in
    (* For sell: adverse means fill below decision, so positive bps *)
    Alcotest.(check (float 1e-6)) "sell slippage positive" 50.0 r.slippage_bps


let test_partial_fill () =
  let order = Helpers.make_order ~side:Order.Buy ~quantity:1000.0 () in
  let fills = [ make_fill ~ts_ns:1_000L ~price:100.0 ~quantity:300.0 () ] in
  let r =
    Execution_quality.analyze ~order ~decision_price:100.0 ~decision_ts_ns:0L ~fills
      ~market_vwap:100.0 in
    Alcotest.(check (float 1e-9)) "fill_rate = 0.3" 0.3 r.fill_rate ;
    Alcotest.(check bool)
      "time_to_full_fill_ns = None" true
      (match r.time_to_full_fill_ns with None -> true | Some _ -> false)


let test_commission_in_implementation_shortfall () =
  let order = Helpers.make_order ~side:Order.Buy ~quantity:100.0 () in
  let fills = [ make_fill ~ts_ns:1L ~price:100.0 ~quantity:100.0 ~commission:50.0 () ] in
  let r =
    Execution_quality.analyze ~order ~decision_price:100.0 ~decision_ts_ns:0L ~fills
      ~market_vwap:100.0 in
    (* slippage = 0; commission = 50 / (100 * 100) = 0.005 = 50 bps *)
    Alcotest.(check (float 1e-6))
      "IS = 50 bps (pure commission)" 50.0 r.implementation_shortfall_bps


let test_empty_fills () =
  let order = Helpers.make_order ~side:Order.Buy ~quantity:100.0 () in
  let r =
    Execution_quality.analyze ~order ~decision_price:100.0 ~decision_ts_ns:0L ~fills:[]
      ~market_vwap:100.0 in
    Alcotest.(check (float 1e-9)) "fill_rate = 0" 0.0 r.fill_rate ;
    Alcotest.(check (float 1e-9)) "slippage = 0" 0.0 r.slippage_bps


let suite =
  [
    Alcotest.test_case "buy_full_fill_slippage_positive" `Quick test_buy_full_fill_slippage_positive;
    Alcotest.test_case "sell_slippage_signed" `Quick test_sell_slippage_signed;
    Alcotest.test_case "partial_fill" `Quick test_partial_fill;
    Alcotest.test_case "commission_in_implementation_shortfall" `Quick
      test_commission_in_implementation_shortfall;
    Alcotest.test_case "empty_fills" `Quick test_empty_fills;
  ]
