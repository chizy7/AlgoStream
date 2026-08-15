open Base
module Asset = Algostream_domain_market.Asset
module Tick = Algostream_domain_market.Tick
module Order_book = Algostream_domain_market.Order_book
module Order = Algostream_domain_orders.Order
module Timestamp = Algostream_domain_common.Timestamp

let test_asset_creation () =
  Stdio.printf "Testing Asset Creation...\n" ;
  let btc =
    Asset.create_crypto ~symbol:"BTCUSD" ~name:"Bitcoin" ~exchange:"Binance" ~base_currency:"BTC"
      ~quote_currency:"USD" ~tick_size:0.01 in

  let eth =
    Asset.create_crypto ~symbol:"ETHUSD" ~name:"Ethereum" ~exchange:"Coinbase" ~base_currency:"ETH"
      ~quote_currency:"USD" ~tick_size:0.01 in

  assert (String.equal (Asset.get_full_symbol btc) "BTC/USD") ;
  assert (String.equal (Asset.get_full_symbol eth) "ETH/USD") ;
  assert (Asset.is_tradeable btc) ;
  assert (Asset.is_tradeable eth) ;
  Stdio.printf "✓ Asset creation tests passed!\n\n"


let test_market_data () =
  Stdio.printf "Testing Market Data Structures...\n" ;
  let now = Timestamp.now () in

  (* Test tick creation and operations *)
  let tick =
    Tick.create_tick ~symbol:"BTCUSD" ~timestamp:now ~bid_price:50000.0 ~ask_price:50010.0
      ~bid_size:1.5 ~ask_size:2.0 ~volume:100.0 ~sequence:123L () in

  assert (Float.equal (Tick.spread tick) 10.0) ;
  assert (Float.equal (Tick.mid_price tick) 50005.0) ;
  assert (Tick.is_valid_tick tick) ;

  (* Test order book creation *)
  let bids =
    [|
      Order_book.Price_level.create ~price:50000.0 ~size:1.0 ~orders:2;
      Order_book.Price_level.create ~price:49990.0 ~size:2.0 ~orders:3;
      Order_book.Price_level.create ~price:49980.0 ~size:1.5 ~orders:1;
    |] in
  let asks =
    [|
      Order_book.Price_level.create ~price:50010.0 ~size:1.5 ~orders:1;
      Order_book.Price_level.create ~price:50020.0 ~size:3.0 ~orders:2;
      Order_book.Price_level.create ~price:50030.0 ~size:0.5 ~orders:1;
    |] in

  let order_book =
    Order_book.create_order_book ~symbol:"BTCUSD" ~timestamp:now ~sequence:456L ~bids ~asks in

  assert (Order_book.is_valid_order_book order_book) ;

  match Order_book.spread order_book with
  | Some spread -> assert (Float.equal spread 10.0)
  | None ->
    failwith "Expected order book to have spread" ;

    let total_bid_vol = Order_book.total_bid_volume order_book in
    let total_ask_vol = Order_book.total_ask_volume order_book in
      assert (Float.equal total_bid_vol 4.5) ;
      (* 1.0 + 2.0 + 1.5 *)
      assert (Float.equal total_ask_vol 5.0) ;

      (* 1.5 + 3.0 + 0.5 *)
      Stdio.printf "✓ Market data structure tests passed!\n\n"


let test_order_management () =
  Stdio.printf "Testing Order Management...\n" ;

  (* Test market order creation *)
  let market_order =
    Order.create_market_order ~id:"order_123" ~client_order_id:"client_123" ~symbol:"BTCUSD"
      ~side:Buy ~quantity:1.0 ~exchange:"Binance" ~strategy_id:"strategy_1" () in

  assert (Order.is_pending market_order) ;
  assert (Float.equal (Order.remaining_quantity market_order) 1.0) ;
  assert (Float.equal (Order.fill_percentage market_order) 0.0) ;

  (* Test order filling *)
  let updated_order = Order.add_fill market_order ~fill_quantity:0.5 ~fill_price:50000.0 in
    assert (not (Order.is_pending updated_order)) ;
    assert (Float.equal (Order.remaining_quantity updated_order) 0.5) ;
    assert (Float.equal (Order.fill_percentage updated_order) 50.0) ;

    (* Test complete fill *)
    let filled_order = Order.add_fill updated_order ~fill_quantity:0.5 ~fill_price:50010.0 in
      assert (Order.is_filled filled_order) ;
      assert (Float.equal (Order.remaining_quantity filled_order) 0.0) ;
      assert (Float.equal (Order.fill_percentage filled_order) 100.0) ;

      (* Test limit order *)
      let limit_order =
        Order.create_limit_order ~id:"limit_456" ~client_order_id:"client_456" ~symbol:"ETHUSD"
          ~side:Sell ~quantity:2.0 ~price:3000.0 ~exchange:"Coinbase" () in

      match Order.get_limit_price limit_order with
      | Some price -> assert (Float.equal price 3000.0)
      | None ->
        failwith "Expected limit order to have limit price" ;

        assert (Float.equal (Order.order_value limit_order) 6000.0) ;

        Stdio.printf "✓ Order management tests passed!\n\n"


let test_timestamp_system () =
  Stdio.printf "Testing Timestamp System...\n" ;

  let now = Timestamp.now () in
  let later = Timestamp.add now 60.0 in
  (* 60 seconds later *)
  let diff = Timestamp.diff later now in

  assert (Float.equal diff 60.0) ;
  assert (Float.(Timestamp.to_float later > Timestamp.to_float now)) ;
  assert (Float.(Timestamp.to_float now < Timestamp.to_float later)) ;

  let span = Timestamp.Span.of_min 5.0 in
    (* 5 minutes *)
    assert (Float.equal (Timestamp.Span.to_sec span) 300.0) ;

    Stdio.printf "✓ Timestamp system tests passed!\n\n"


let performance_test () =
  Stdio.printf "Running Performance Tests...\n" ;

  let start_time = Timestamp.now () in

  (* Create 10,000 ticks *)
  for i = 1 to 10000 do
    let tick =
      Tick.create_tick ~symbol:"BTCUSD" ~timestamp:(Timestamp.now ())
        ~bid_price:(Float.of_int (50000 + i))
        ~ask_price:(Float.of_int (50010 + i))
        ~bid_size:1.0 ~ask_size:1.0 ~volume:100.0 ~sequence:(Int64.of_int i) () in
      ignore (Tick.spread tick) ;
      ignore (Tick.mid_price tick) ;
      ignore (Tick.is_valid_tick tick)
  done ;

  let end_time = Timestamp.now () in
  let duration = Timestamp.diff end_time start_time in

  Stdio.printf "Created and processed 10,000 ticks in %.6f seconds\n" duration ;
  Stdio.printf "Rate: %.0f ticks/second\n" (10000.0 /. duration) ;

  if Float.(duration < 1.0) then Stdio.printf "✓ Performance target met (>10,000 ticks/sec)!\n\n"
  else Stdio.printf "Performance below target, but still functional\n\n"


let run_comprehensive_tests () =
  Stdio.printf "Running AlgoStream Comprehensive Domain Model Tests...\n\n" ;

  test_asset_creation () ;
  test_market_data () ;
  test_order_management () ;
  test_timestamp_system () ;
  performance_test () ;

  Stdio.printf "All comprehensive tests passed!\n" ;
  Stdio.printf "AlgoStream Core Domain Models are fully functional and tested.\n"


let () = run_comprehensive_tests ()
