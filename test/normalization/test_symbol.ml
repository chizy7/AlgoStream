module S = Algostream_normalization.Symbol

let test_parse_binance () =
  match S.parse ~exchange:"binance" ~raw:"BTCUSDT" with
  | Some s ->
    Alcotest.(check string) "base" "BTC" s.base ;
    Alcotest.(check string) "quote" "USDT" s.quote
  | None -> Alcotest.fail "expected canonical for binance/BTCUSDT"


let test_parse_coinbase () =
  match S.parse ~exchange:"coinbase" ~raw:"BTC-USD" with
  | Some s ->
    Alcotest.(check string) "base" "BTC" s.base ;
    Alcotest.(check string) "quote" "USD" s.quote
  | None -> Alcotest.fail "expected canonical for coinbase/BTC-USD"


let test_to_canonical () =
  let s = { S.base = "BTC"; quote = "USDT"; asset_class = Crypto } in
    Alcotest.(check string) "BTC/USDT" "BTC/USDT" (S.to_canonical s)


let test_unknown_returns_none () =
  Alcotest.(check bool)
    "unknown exchange" true
    (Option.is_none (S.parse ~exchange:"nope" ~raw:"BTC-USD"))


let test_register_then_parse () =
  let canonical = { S.base = "TEST"; quote = "USD"; asset_class = Crypto } in
    S.register ~exchange:"testex" ~raw:"TESTUSD" canonical ;
    match S.parse ~exchange:"testex" ~raw:"TESTUSD" with
    | Some s -> Alcotest.(check bool) "registered round-trips" true (S.equal s canonical)
    | None -> Alcotest.fail "registered symbol not found"


let test_to_exchange_inverse () =
  let s = { S.base = "BTC"; quote = "USDT"; asset_class = Crypto } in
    Alcotest.(check (option string))
      "to binance" (Some "BTCUSDT")
      (S.to_exchange s ~exchange:"binance")


let test_usdt_vs_usd_distinct () =
  let a = S.parse ~exchange:"binance" ~raw:"BTCUSDT" |> Option.get in
  let b = S.parse ~exchange:"coinbase" ~raw:"BTC-USD" |> Option.get in
    Alcotest.(check bool) "different canonicals" false (S.equal a b)


let suite =
  [
    Alcotest.test_case "parse_binance" `Quick test_parse_binance;
    Alcotest.test_case "parse_coinbase" `Quick test_parse_coinbase;
    Alcotest.test_case "to_canonical" `Quick test_to_canonical;
    Alcotest.test_case "unknown_returns_none" `Quick test_unknown_returns_none;
    Alcotest.test_case "register_then_parse" `Quick test_register_then_parse;
    Alcotest.test_case "to_exchange_inverse" `Quick test_to_exchange_inverse;
    Alcotest.test_case "usdt_vs_usd_distinct" `Quick test_usdt_vs_usd_distinct;
  ]
