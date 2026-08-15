module V = Algostream_normalization.Validator
module Asset = Algostream_domain_market.Asset

let mk_asset ~tick_size ~min_size =
  {
    Asset.symbol = "TEST";
    name = "Test";
    asset_class = Crypto;
    exchange = "test";
    base_currency = Some "TEST";
    quote_currency = Some "USD";
    min_trade_size = min_size;
    tick_size;
    multiplier = 1.0;
    active = true;
  }


let test_passes_grid_aligned () =
  let a = mk_asset ~tick_size:0.01 ~min_size:0.001 in
    Alcotest.(check bool)
      "100.05 on grid" true
      (Option.is_none (V.check_tick a ~price:100.05 ~size:1.0))


let test_rejects_off_grid () =
  let a = mk_asset ~tick_size:0.01 ~min_size:0.001 in
    match V.check_tick a ~price:100.005 ~size:1.0 with
    | Some (Tick_size_violation _) -> ()
    | _ -> Alcotest.fail "expected Tick_size_violation"


let test_rejects_below_min_size () =
  let a = mk_asset ~tick_size:0.01 ~min_size:0.5 in
    match V.check_tick a ~price:100.0 ~size:0.1 with
    | Some (Min_trade_size_violation _) -> ()
    | _ -> Alcotest.fail "expected Min_trade_size_violation"


let suite =
  [
    Alcotest.test_case "passes_grid_aligned" `Quick test_passes_grid_aligned;
    Alcotest.test_case "rejects_off_grid" `Quick test_rejects_off_grid;
    Alcotest.test_case "rejects_below_min_size" `Quick test_rejects_below_min_size;
  ]
