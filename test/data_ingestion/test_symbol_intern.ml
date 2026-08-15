module SI = Algostream_data_ingestion.Symbol_intern

let fresh_copy s = Bytes.to_string (Bytes.of_string s)

let test_intern_returns_physical_equal () =
  let t = SI.create () in
  let a = SI.intern t "BTCUSDT" in
  let b = SI.intern t (fresh_copy "BTCUSDT") in
    Alcotest.(check bool) "second intern reuses canonical string" true (a == b)


let test_distinct_inputs_distinct_outputs () =
  let t = SI.create () in
  let a = SI.intern t "BTCUSDT" in
  let b = SI.intern t "ETHUSDT" in
    Alcotest.(check string) "first ok" "BTCUSDT" a ;
    Alcotest.(check string) "second ok" "ETHUSDT" b ;
    Alcotest.(check int) "table size 2" 2 (SI.size t)


let test_intern_bytes () =
  let t = SI.create () in
  let buf = Bytes.of_string "_BTCUSDT_" in
  let a = SI.intern_bytes t buf ~off:1 ~len:7 in
  let b = SI.intern t "BTCUSDT" in
    Alcotest.(check bool) "intern_bytes joins same canonical" true (a == b)


let suite =
  [
    Alcotest.test_case "intern_returns_physical_equal" `Quick test_intern_returns_physical_equal;
    Alcotest.test_case "distinct_inputs_distinct_outputs" `Quick
      test_distinct_inputs_distinct_outputs;
    Alcotest.test_case "intern_bytes" `Quick test_intern_bytes;
  ]
