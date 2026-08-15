module Parser = Algostream_data_ingestion_coinbase.Parser
module SI = Algostream_data_ingestion.Symbol_intern

let contains_substring haystack needle =
  let nl = String.length needle in
  let hl = String.length haystack in
  let rec loop i =
    if i + nl > hl then false else if String.sub haystack i nl = needle then true else loop (i + 1)
  in
    loop 0


let ticker =
  {|{"type":"ticker","sequence":37475248783,"product_id":"BTC-USD","price":"50000.15","best_bid":"50000.10","best_bid_size":"0.5","best_ask":"50000.20","best_ask_size":"0.7","time":"2022-10-19T23:28:22.061769Z"}|}


let match_msg =
  {|{"type":"match","trade_id":12345,"sequence":50,"product_id":"BTC-USD","price":"50000.15","size":"0.01","side":"buy","time":"2022-10-19T23:28:22.061769Z"}|}


let subscribe_ack =
  {|{"type":"subscriptions","channels":[{"name":"ticker","product_ids":["BTC-USD"]}]}|}


let test_subscribe_message () =
  let msg = Parser.build_subscribe_message ~symbols:[ "BTC-USD"; "ETH-USD" ] in
    Alcotest.(check bool) "subscribe type" true (contains_substring msg "\"subscribe\"") ;
    Alcotest.(check bool) "ticker channel" true (contains_substring msg "\"ticker\"") ;
    Alcotest.(check bool) "matches channel" true (contains_substring msg "\"matches\"") ;
    Alcotest.(check bool) "BTC-USD" true (contains_substring msg "BTC-USD")


let test_ticker () =
  let si = SI.create () in
    match Parser.parse_frame ~symbol_intern:si ticker with
    | [ Market_tick { symbol; bid; ask; price; _ } ] ->
      Alcotest.(check string) "symbol" "BTC-USD" symbol ;
      Alcotest.(check (float 1e-9)) "bid" 50000.10 bid ;
      Alcotest.(check (float 1e-9)) "ask" 50000.20 ask ;
      Alcotest.(check (float 1e-9)) "price" 50000.15 price
    | _ -> Alcotest.fail "expected one Market_tick"


let test_match () =
  let si = SI.create () in
    match Parser.parse_frame ~symbol_intern:si match_msg with
    | [ Trade_print { symbol; price; size; side; trade_id; sequence; _ } ] ->
      Alcotest.(check string) "symbol" "BTC-USD" symbol ;
      Alcotest.(check (float 1e-9)) "price" 50000.15 price ;
      Alcotest.(check (float 1e-9)) "size" 0.01 size ;
      Alcotest.(check string) "side" "buy" side ;
      Alcotest.(check string) "trade_id" "12345" trade_id ;
      (* The trade id, not the message's "sequence" field (50 in this fixture). Coinbase's sequence
         counts the product's whole full channel while this connector subscribes only to matches, so
         it advances far faster than the messages we receive and every match read as a gap. *)
      Alcotest.(check int64) "sequence is the trade id" 12345L sequence
    | _ -> Alcotest.fail "expected one Trade_print"


let test_subscribe_ack_ignored () =
  let si = SI.create () in
    Alcotest.(check int)
      "no payloads" 0
      (List.length (Parser.parse_frame ~symbol_intern:si subscribe_ack))


let suite =
  [
    Alcotest.test_case "subscribe_message" `Quick test_subscribe_message;
    Alcotest.test_case "ticker" `Quick test_ticker;
    Alcotest.test_case "match" `Quick test_match;
    Alcotest.test_case "subscribe_ack_ignored" `Quick test_subscribe_ack_ignored;
  ]
