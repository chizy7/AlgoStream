module FH = Algostream_normalization.Feed_health

let test_basic_observe () =
  let fh = FH.create ~max_sources:8 () in
    FH.observe fh ~source:"binance" ~ts_ns:1L ~latency_ns:100L ;
    FH.observe fh ~source:"binance" ~ts_ns:2L ~latency_ns:200L ;
    match FH.per_source fh ~source:"binance" with
    | Some s ->
      Alcotest.(check int64) "ticks" 2L s.ticks ;
      Alcotest.(check int64) "last_ts" 2L s.last_event_ts_ns
    | None -> Alcotest.fail "expected stats for binance"


let test_record_gap () =
  let fh = FH.create ~max_sources:8 () in
    FH.record_gap fh ~source:"coinbase" ;
    FH.record_gap fh ~source:"coinbase" ;
    match FH.per_source fh ~source:"coinbase" with
    | Some s -> Alcotest.(check int64) "gaps" 2L s.gaps
    | None -> Alcotest.fail "expected stats for coinbase"


let test_unknown_returns_none () =
  let fh = FH.create () in
    Alcotest.(check bool) "none" true (Option.is_none (FH.per_source fh ~source:"nope"))


let test_lru_eviction () =
  let fh = FH.create ~max_sources:3 () in
    FH.observe fh ~source:"a" ~ts_ns:1L ~latency_ns:0L ;
    FH.observe fh ~source:"b" ~ts_ns:2L ~latency_ns:0L ;
    FH.observe fh ~source:"c" ~ts_ns:3L ~latency_ns:0L ;
    Alcotest.(check int) "3 active" 3 (FH.active_count fh) ;
    FH.observe fh ~source:"d" ~ts_ns:4L ~latency_ns:0L ;
    Alcotest.(check int) "still 3 after eviction" 3 (FH.active_count fh) ;
    Alcotest.(check bool) "a evicted" true (Option.is_none (FH.per_source fh ~source:"a"))


let suite =
  [
    Alcotest.test_case "basic_observe" `Quick test_basic_observe;
    Alcotest.test_case "record_gap" `Quick test_record_gap;
    Alcotest.test_case "unknown_returns_none" `Quick test_unknown_returns_none;
    Alcotest.test_case "lru_eviction" `Quick test_lru_eviction;
  ]
