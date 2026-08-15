open Algostream_order_management
module Order = Algostream_domain_orders.Order

let test_fee_tier_at_low_volume () =
  let v = Venue.binance_spot in
  let fee = Venue.effective_fee_bps v ~taker:true ~monthly_volume:0.0 in
    Alcotest.(check (float 1e-9)) "binance taker at $0/mo" 10.0 fee


let test_fee_tier_with_multiple_tiers () =
  let v =
    Venue.create ~name:"custom" ~asset_class:Algostream_domain_market.Asset.Crypto
      ~fee_tiers:
        [
          { maker_bps = 10.0; taker_bps = 10.0; volume_threshold = 0.0 };
          { maker_bps = 5.0; taker_bps = 7.0; volume_threshold = 1_000_000.0 };
          { maker_bps = 2.0; taker_bps = 4.0; volume_threshold = 10_000_000.0 };
        ]
      ~base_latency_us:50_000.0 ~supports_iceberg:true ~supports_stop:true ~min_order_size:1.0 in
    Alcotest.(check (float 1e-9))
      "low tier" 10.0
      (Venue.effective_fee_bps v ~taker:true ~monthly_volume:500.0) ;
    Alcotest.(check (float 1e-9))
      "mid tier" 7.0
      (Venue.effective_fee_bps v ~taker:true ~monthly_volume:5_000_000.0) ;
    Alcotest.(check (float 1e-9))
      "top tier" 4.0
      (Venue.effective_fee_bps v ~taker:true ~monthly_volume:50_000_000.0)


let test_supports_order_kinds () =
  let cb = Venue.coinbase_advanced in
    Alcotest.(check bool) "market always" true (Venue.supports cb ~kind:Order.Market) ;
    Alcotest.(check bool) "limit always" true (Venue.supports cb ~kind:(Order.Limit 100.0)) ;
    Alcotest.(check bool)
      "iceberg unsupported on coinbase advanced" false
      (Venue.supports cb ~kind:(Order.Iceberg { display_size = 10.0; total_size = 100.0 })) ;
    let bn = Venue.binance_spot in
      Alcotest.(check bool)
        "iceberg supported on binance" true
        (Venue.supports bn ~kind:(Order.Iceberg { display_size = 10.0; total_size = 100.0 }))


let suite =
  [
    Alcotest.test_case "fee_tier_at_low_volume" `Quick test_fee_tier_at_low_volume;
    Alcotest.test_case "fee_tier_with_multiple_tiers" `Quick test_fee_tier_with_multiple_tiers;
    Alcotest.test_case "supports_order_kinds" `Quick test_supports_order_kinds;
  ]
