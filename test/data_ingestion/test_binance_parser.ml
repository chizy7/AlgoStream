module Parser = Algostream_data_ingestion_binance.Parser
module SI = Algostream_data_ingestion.Symbol_intern
module Event_types = Algostream_infrastructure_event_bus.Event_types

let contains_substring haystack needle =
  let nl = String.length needle in
  let hl = String.length haystack in
  let rec loop i =
    if i + nl > hl then false else if String.sub haystack i nl = needle then true else loop (i + 1)
  in
    loop 0


(* Sample frames. Numbers and ID values are arbitrary but realistic. *)

let book_ticker =
  {|{"u":400900217,"s":"BTCUSDT","b":"50000.10","B":"0.5","a":"50000.20","A":"0.7"}|}


let trade =
  {|{"e":"trade","E":1591241801500,"s":"BTCUSDT","t":12345,"p":"50000.15","q":"0.01","b":88,"a":50,"T":1591241801499,"m":true,"M":true}|}


let combined_book_ticker =
  {|{"stream":"btcusdt@bookTicker","data":{"u":1,"s":"BTCUSDT","b":"50000.10","B":"0.5","a":"50000.20","A":"0.7"}}|}


let subscribe_ack = {|{"result":null,"id":1}|}

let test_subscribe_message () =
  let msg = Parser.build_subscribe_message ~symbols:[ "BTCUSDT"; "ETHUSDT" ] in
    Alcotest.(check bool)
      "contains btcusdt@bookTicker" true
      (contains_substring msg "btcusdt@bookTicker") ;
    Alcotest.(check bool) "contains btcusdt@trade" true (contains_substring msg "btcusdt@trade") ;
    Alcotest.(check bool) "contains ethusdt@trade" true (contains_substring msg "ethusdt@trade")


let test_book_ticker () =
  let si = SI.create () in
    match Parser.parse_frame ~symbol_intern:si book_ticker with
    | [ Market_tick { symbol; bid; ask; volume; price; _ } ] ->
      Alcotest.(check string) "symbol" "BTCUSDT" symbol ;
      Alcotest.(check (float 1e-9)) "bid" 50000.10 bid ;
      Alcotest.(check (float 1e-9)) "ask" 50000.20 ask ;
      Alcotest.(check (float 1e-9)) "volume" 1.2 volume ;
      Alcotest.(check (float 1e-9)) "mid" 50000.15 price
    | _ -> Alcotest.fail "expected one Market_tick"


let test_trade () =
  let si = SI.create () in
    match Parser.parse_frame ~symbol_intern:si trade with
    | [ Trade_print { symbol; price; size; side; trade_id; sequence; timestamp_ns } ] ->
      Alcotest.(check string) "symbol" "BTCUSDT" symbol ;
      Alcotest.(check (float 1e-9)) "price" 50000.15 price ;
      Alcotest.(check (float 1e-9)) "size" 0.01 size ;
      Alcotest.(check string) "side" "sell" side ;
      (* m=true → maker is buyer → trade was a sell *)
      Alcotest.(check string) "trade_id" "12345" trade_id ;
      (* The trade id, not "T". [sequence] previously carried the trade timestamp in milliseconds —
         1591241801499 in this fixture — which Data_quality then compared as though it were a
         message counter, reporting the milliseconds between trades as dropped messages. The two
         values are deliberately different here so this test tells them apart. *)
      Alcotest.(check int64) "sequence is the trade id" 12345L sequence ;
      Alcotest.(check int64) "timestamp_ns matches T*1e6" 1591241801499_000_000L timestamp_ns
    | _ -> Alcotest.fail "expected one Trade_print"


let test_combined_stream_unwrapping () =
  let si = SI.create () in
    match Parser.parse_frame ~symbol_intern:si combined_book_ticker with
    | [ Market_tick { symbol; _ } ] -> Alcotest.(check string) "unwrapped symbol" "BTCUSDT" symbol
    | _ -> Alcotest.fail "expected one Market_tick from combined stream"


let test_subscribe_ack_ignored () =
  let si = SI.create () in
  let payloads = Parser.parse_frame ~symbol_intern:si subscribe_ack in
    Alcotest.(check int) "control message yields no payloads" 0 (List.length payloads)


let test_malformed_ignored () =
  let si = SI.create () in
  let payloads = Parser.parse_frame ~symbol_intern:si "}}}not valid json" in
    Alcotest.(check int) "malformed yields no payloads" 0 (List.length payloads)


let suite =
  [
    Alcotest.test_case "subscribe_message" `Quick test_subscribe_message;
    Alcotest.test_case "book_ticker" `Quick test_book_ticker;
    Alcotest.test_case "trade" `Quick test_trade;
    Alcotest.test_case "combined_stream_unwrapping" `Quick test_combined_stream_unwrapping;
    Alcotest.test_case "subscribe_ack_ignored" `Quick test_subscribe_ack_ignored;
    Alcotest.test_case "malformed_ignored" `Quick test_malformed_ignored;
  ]


let _ = Event_types.Event.Heartbeat
