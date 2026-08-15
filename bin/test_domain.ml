open Base
module Asset = Algostream_domain_market.Asset
module Tick = Algostream_domain_market.Tick
module Order_book = Algostream_domain_market.Order_book
module Timestamp = Algostream_domain_common.Timestamp

let test_asset_creation () =
  let btc =
    Asset.create_crypto ~symbol:"BTCUSD" ~name:"Bitcoin" ~exchange:"Binance" ~base_currency:"BTC"
      ~quote_currency:"USD" ~tick_size:0.01 in

  Stdio.printf "Created asset: %s\n" (Asset.get_full_symbol btc) ;
  Stdio.printf "Is tradeable: %b\n" (Asset.is_tradeable btc) ;
  assert (String.equal (Asset.get_full_symbol btc) "BTC/USD") ;
  Stdio.printf "✓ Asset creation test passed!\n"


let test_tick_operations () =
  let now = Timestamp.now () in
  let tick =
    Tick.create_tick ~symbol:"BTCUSD" ~timestamp:now ~bid_price:50000.0 ~ask_price:50010.0
      ~bid_size:1.5 ~ask_size:2.0 ~volume:100.0 ~sequence:123L () in

  let spread = Tick.spread tick in
  let mid = Tick.mid_price tick in
  let valid = Tick.is_valid_tick tick in

  Stdio.printf "Tick spread: %.2f\n" spread ;
  Stdio.printf "Mid price: %.2f\n" mid ;
  Stdio.printf "Is valid: %b\n" valid ;

  assert (Float.equal spread 10.0) ;
  assert (Float.equal mid 50005.0) ;
  assert valid ;
  Stdio.printf "✓ Tick operations test passed!\n"


let test_order_book () =
  let now = Timestamp.now () in
  let bids =
    [|
      Order_book.Price_level.create ~price:50000.0 ~size:1.0 ~orders:2;
      Order_book.Price_level.create ~price:49990.0 ~size:2.0 ~orders:3;
    |] in
  let asks =
    [|
      Order_book.Price_level.create ~price:50010.0 ~size:1.5 ~orders:1;
      Order_book.Price_level.create ~price:50020.0 ~size:3.0 ~orders:2;
    |] in

  let order_book =
    Order_book.create_order_book ~symbol:"BTCUSD" ~timestamp:now ~sequence:456L ~bids ~asks in

  match Order_book.spread order_book with
  | Some spread ->
    Stdio.printf "Order book spread: %.2f\n" spread ;
    assert (Float.equal spread 10.0) ;
    Stdio.printf "✓ Order book test passed!\n"
  | None ->
    Stdio.printf "Order book test failed - no spread!\n" ;
    assert false


let run_tests () =
  Stdio.printf "Running AlgoStream Domain Model Tests...\n\n" ;

  test_asset_creation () ;
  Stdio.printf "\n" ;

  test_tick_operations () ;
  Stdio.printf "\n" ;

  test_order_book () ;
  Stdio.printf "\n" ;

  Stdio.printf "All tests passed! Domain models are working correctly.\n"


let () = run_tests ()
