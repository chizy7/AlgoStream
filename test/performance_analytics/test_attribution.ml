module Attr = Algostream_performance.Attribution
module Regime = Algostream_analytics.Regime

let sec = 1_000_000_000L

let fill ?(symbol = "BTC") ?(strategy_id = "s1") ?(is_maker = false) ~i ~qty ~price ~commission
  ~slippage ~pnl () =
  {
    Attr.ts_ns = Int64.mul (Int64.of_int i) sec;
    symbol;
    signed_quantity = qty;
    price;
    commission;
    slippage_cost = slippage;
    financing_cost = 0.0;
    is_maker;
    strategy_id;
    realized_pnl_after = pnl;
  }


(* Two symbols with known realized P&L deltas: BTC ends at +100, ETH contributes +50. *)
let blotter =
  [|
    fill ~symbol:"BTC" ~i:0 ~qty:1.0 ~price:100.0 ~commission:1.0 ~slippage:0.5 ~pnl:0.0 ();
    fill ~symbol:"BTC" ~i:1 ~qty:(-1.0) ~price:200.0 ~commission:1.0 ~slippage:0.5 ~pnl:100.0 ();
    fill ~symbol:"ETH" ~i:2 ~qty:2.0 ~price:50.0 ~commission:0.5 ~slippage:0.25 ~pnl:100.0 ();
    fill ~symbol:"ETH" ~i:3 ~qty:(-2.0) ~price:75.0 ~commission:0.5 ~slippage:0.25 ~pnl:150.0 ();
  |]


let find name arr = Array.find_opt (fun c -> String.equal c.Attr.key name) arr

let test_by_symbol_splits_realized_pnl () =
  let cs = Attr.by_symbol blotter in
    Alcotest.(check int) "two symbols" 2 (Array.length cs) ;
    (match find "BTC" cs with
    | Some c ->
      Alcotest.(check (float 1e-9)) "BTC realized" 100.0 c.Attr.realized_pnl ;
      Alcotest.(check (float 1e-9)) "BTC commission" 2.0 c.Attr.commission ;
      Alcotest.(check int) "BTC fills" 2 c.Attr.n_fills
    | None -> Alcotest.fail "BTC missing") ;
    match find "ETH" cs with
    | Some c -> Alcotest.(check (float 1e-9)) "ETH realized" 50.0 c.Attr.realized_pnl
    | None -> Alcotest.fail "ETH missing"


let test_net_pnl_subtracts_costs () =
  let cs = Attr.by_symbol blotter in
    match find "BTC" cs with
    | Some c ->
      (* 100 realized - 2 commission - 1 slippage = 97 *)
      Alcotest.(check (float 1e-9)) "net = realized - costs" 97.0 c.Attr.net_pnl
    | None -> Alcotest.fail "BTC missing"


let test_percentages_sum_to_one () =
  let cs = Attr.by_symbol blotter in
  let total = Array.fold_left (fun a c -> a +. c.Attr.pct_of_net) 0.0 cs in
    Alcotest.(check (float 1e-9)) "shares sum to 1" 1.0 total


let test_sorted_by_absolute_contribution () =
  let cs = Attr.by_symbol blotter in
    Alcotest.(check string) "largest contributor first" "BTC" cs.(0).Attr.key


let test_by_side () =
  let cs = Attr.by_side blotter in
    Alcotest.(check int) "buy and sell" 2 (Array.length cs) ;
    Alcotest.(check bool)
      "both groups present" true
      (find "buy" cs <> None && find "sell" cs <> None)


let test_by_liquidity () =
  let mixed =
    [|
      fill ~is_maker:true ~i:0 ~qty:1.0 ~price:100.0 ~commission:0.1 ~slippage:0.0 ~pnl:0.0 ();
      fill ~is_maker:false ~i:1 ~qty:(-1.0) ~price:110.0 ~commission:1.0 ~slippage:0.5 ~pnl:10.0 ();
    |] in
  let cs = Attr.by_liquidity mixed in
    Alcotest.(check int) "maker and taker" 2 (Array.length cs) ;
    match (find "maker" cs, find "taker" cs) with
    | Some m, Some t ->
      Alcotest.(check (float 1e-9)) "maker commission" 0.1 m.Attr.commission ;
      Alcotest.(check (float 1e-9)) "taker commission" 1.0 t.Attr.commission
    | _ -> Alcotest.fail "expected both liquidity groups"


let test_by_strategy () =
  let two =
    [|
      fill ~strategy_id:"a" ~i:0 ~qty:1.0 ~price:100.0 ~commission:0.0 ~slippage:0.0 ~pnl:0.0 ();
      fill ~strategy_id:"b" ~i:1 ~qty:1.0 ~price:100.0 ~commission:0.0 ~slippage:0.0 ~pnl:20.0 ();
    |] in
  let cs = Attr.by_strategy two in
    Alcotest.(check int) "two strategies" 2 (Array.length cs)


let test_by_regime_labels_and_handles_unlabelled () =
  let regimes = [| (Int64.mul 2L sec, Regime.Crisis) |] in
  let cs = Attr.by_regime blotter ~regimes in
    (* Fills at t=0 and t=1 precede the first label. *)
    Alcotest.(check bool) "early fills are grouped as unlabelled" true (find "unlabelled" cs <> None) ;
    Alcotest.(check bool)
      "later fills carry the regime label" true
      (find (Regime.to_string Regime.Crisis) cs <> None)


let test_cost_waterfall () =
  let w = Attr.cost_waterfall blotter in
    Alcotest.(check (float 1e-9))
      "gross is the final cumulative realized P&L" 150.0 w.Attr.gross_pnl ;
    Alcotest.(check (float 1e-9)) "total commission" 3.0 w.Attr.commission ;
    Alcotest.(check (float 1e-9)) "total slippage" 1.5 w.Attr.slippage ;
    Alcotest.(check (float 1e-9)) "net = gross - costs" (150.0 -. 4.5) w.Attr.net_pnl ;
    Alcotest.(check (float 1e-9)) "cost ratio" (4.5 /. 150.0) w.Attr.cost_ratio


let test_empty_blotter () =
  let w = Attr.cost_waterfall [||] in
    Alcotest.(check (float 1e-12)) "gross 0" 0.0 w.Attr.gross_pnl ;
    Alcotest.(check int) "no groups" 0 (Array.length (Attr.by_symbol [||]))


let test_holding_buckets () =
  let cs = Attr.by_holding_bucket blotter ~buckets_ns:[| sec; Int64.mul 10L sec |] in
    Alcotest.(check bool) "some bucket was produced" true (Array.length cs > 0)


let suite =
  [
    Alcotest.test_case "by_symbol_splits_realized_pnl" `Quick test_by_symbol_splits_realized_pnl;
    Alcotest.test_case "net_pnl_subtracts_costs" `Quick test_net_pnl_subtracts_costs;
    Alcotest.test_case "percentages_sum_to_one" `Quick test_percentages_sum_to_one;
    Alcotest.test_case "sorted_by_absolute_contribution" `Quick test_sorted_by_absolute_contribution;
    Alcotest.test_case "by_side" `Quick test_by_side;
    Alcotest.test_case "by_liquidity" `Quick test_by_liquidity;
    Alcotest.test_case "by_strategy" `Quick test_by_strategy;
    Alcotest.test_case "by_regime_labels_and_handles_unlabelled" `Quick
      test_by_regime_labels_and_handles_unlabelled;
    Alcotest.test_case "cost_waterfall" `Quick test_cost_waterfall;
    Alcotest.test_case "empty_blotter" `Quick test_empty_blotter;
    Alcotest.test_case "holding_buckets" `Quick test_holding_buckets;
  ]
