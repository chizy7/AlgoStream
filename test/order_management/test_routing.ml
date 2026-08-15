open Algostream_order_management
module Order = Algostream_domain_orders.Order

let cheap_v =
  Venue.create ~name:"cheap" ~asset_class:Algostream_domain_market.Asset.Crypto
    ~fee_tiers:[ { maker_bps = 2.0; taker_bps = 3.0; volume_threshold = 0.0 } ]
    ~base_latency_us:30_000.0 ~supports_iceberg:true ~supports_stop:true ~min_order_size:1.0


let pricey_v =
  Venue.create ~name:"pricey" ~asset_class:Algostream_domain_market.Asset.Crypto
    ~fee_tiers:[ { maker_bps = 20.0; taker_bps = 25.0; volume_threshold = 0.0 } ]
    ~base_latency_us:50_000.0 ~supports_iceberg:true ~supports_stop:true ~min_order_size:1.0


let mid_v =
  Venue.create ~name:"mid" ~asset_class:Algostream_domain_market.Asset.Crypto
    ~fee_tiers:[ { maker_bps = 8.0; taker_bps = 10.0; volume_threshold = 0.0 } ]
    ~base_latency_us:40_000.0 ~supports_iceberg:true ~supports_stop:true ~min_order_size:1.0


let snap venue ?(best_bid = 100.0) ?(best_ask = 100.1) ?(bid_depth = 1000.0) ?(ask_depth = 1000.0)
  ?(monthly_volume = 0.0) () =
  Routing.{ venue; best_bid; best_ask; bid_depth; ask_depth; monthly_volume }


let test_cheapest_picks_lowest_fee () =
  let order = Helpers.make_order ~quantity:100.0 () in
  let venues =
    [
      snap pricey_v ~best_ask:100.0 ();
      (* cheaper price *)
      snap cheap_v ~best_ask:100.2 ();
      (* lowest fee *)
      snap mid_v ~best_ask:100.1 ();
    ] in
  let r = Routing.route ~order ~venues ~strategy:Routing.Cheapest_venue () in
    Alcotest.(check int) "single allocation" 1 (List.length r.allocations) ;
    Alcotest.(check string) "venue = cheap" "cheap" (List.hd r.allocations).venue_name


let test_best_price_picks_tightest_ask () =
  let order = Helpers.make_order ~quantity:100.0 ~side:Order.Buy () in
  let venues =
    [
      snap pricey_v ~best_ask:100.5 ();
      snap cheap_v ~best_ask:100.2 ();
      snap mid_v ~best_ask:100.1 ();
      (* tightest *)
    ] in
  let r = Routing.route ~order ~venues ~strategy:Routing.Best_price () in
    Alcotest.(check string) "venue = mid" "mid" (List.hd r.allocations).venue_name


let test_best_price_for_sell_picks_highest_bid () =
  let order = Helpers.make_order ~quantity:100.0 ~side:Order.Sell () in
  let venues =
    [
      snap pricey_v ~best_bid:99.5 ();
      snap cheap_v ~best_bid:99.9 ();
      (* highest *)
      snap mid_v ~best_bid:99.7 ();
    ] in
  let r = Routing.route ~order ~venues ~strategy:Routing.Best_price () in
    Alcotest.(check string) "venue = cheap (highest bid)" "cheap" (List.hd r.allocations).venue_name


let test_smart_split_walks_venues_until_quantity_met () =
  let order = Helpers.make_order ~quantity:300.0 () in
  let venues =
    [
      snap cheap_v ~best_ask:100.1 ~ask_depth:100.0 ();
      snap mid_v ~best_ask:100.2 ~ask_depth:100.0 ();
      snap pricey_v ~best_ask:100.3 ~ask_depth:200.0 ();
    ] in
  let r = Routing.route ~order ~venues ~strategy:Routing.Smart_split () in
  let total_alloc = List.fold_left (fun acc a -> acc +. a.Routing.quantity) 0.0 r.allocations in
    Alcotest.(check (float 1e-9)) "total = 300" 300.0 total_alloc ;
    Alcotest.(check (float 1e-9)) "no unallocated" 0.0 r.unallocated ;
    Alcotest.(check int) "3 venues used" 3 (List.length r.allocations)


let test_smart_split_unallocated_when_thin () =
  let order = Helpers.make_order ~quantity:1000.0 () in
  let venues =
    [
      snap cheap_v ~best_ask:100.1 ~ask_depth:200.0 ();
      snap mid_v ~best_ask:100.2 ~ask_depth:100.0 ();
    ] in
  let r = Routing.route ~order ~venues ~strategy:Routing.Smart_split () in
    Alcotest.(check (float 1e-9)) "unallocated = 700" 700.0 r.unallocated


let test_no_eligible_venue () =
  let order =
    Helpers.make_order ~quantity:50.0
      ~order_type:(Order.Iceberg { display_size = 5.0; total_size = 50.0 })
      () in
  let venues = [ snap Venue.coinbase_advanced () ] in
  (* coinbase doesn't support iceberg *)
  let r = Routing.route ~order ~venues ~strategy:Routing.Smart_split () in
    Alcotest.(check (float 1e-9)) "all unallocated" 50.0 r.unallocated ;
    Alcotest.(check int) "no allocations" 0 (List.length r.allocations)


let suite =
  [
    Alcotest.test_case "cheapest_picks_lowest_fee" `Quick test_cheapest_picks_lowest_fee;
    Alcotest.test_case "best_price_picks_tightest_ask" `Quick test_best_price_picks_tightest_ask;
    Alcotest.test_case "best_price_for_sell_picks_highest_bid" `Quick
      test_best_price_for_sell_picks_highest_bid;
    Alcotest.test_case "smart_split_walks_venues_until_quantity_met" `Quick
      test_smart_split_walks_venues_until_quantity_met;
    Alcotest.test_case "smart_split_unallocated_when_thin" `Quick
      test_smart_split_unallocated_when_thin;
    Alcotest.test_case "no_eligible_venue" `Quick test_no_eligible_venue;
  ]
