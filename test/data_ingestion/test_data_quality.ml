module DQ = Algostream_data_ingestion.Data_quality

let stats_zero =
  {
    DQ.total_observed = 0;
    sequence_gaps = 0;
    dropped_to_gap = 0;
    stale_ticks = 0;
    crossed_books = 0;
    out_of_order_trades = 0;
  }


let test_ok_publish () =
  let dq = DQ.create ~exchange:"test" () in
  let v =
    DQ.check_market_tick dq ~symbol:"BTC" ~exchange_ts_ns:100L ~ingest_ts_ns:100L ~bid:99.0
      ~ask:101.0 ~sequence:(Some 1L) in
    match v with Ok_publish -> () | _ -> Alcotest.fail "expected Ok_publish"


let test_crossed_book () =
  let dq = DQ.create ~exchange:"test" () in
  let v =
    DQ.check_market_tick dq ~symbol:"BTC" ~exchange_ts_ns:100L ~ingest_ts_ns:100L ~bid:101.0
      ~ask:99.0 ~sequence:(Some 1L) in
    (match v with Drop_crossed _ -> () | _ -> Alcotest.fail "expected Drop_crossed") ;
    let s = DQ.stats dq in
      Alcotest.(check int) "crossed counter" 1 s.crossed_books


let test_stale_tick () =
  let dq = DQ.create ~exchange:"test" () in
  let v =
    DQ.check_market_tick dq ~symbol:"BTC" ~exchange_ts_ns:0L
      ~ingest_ts_ns:2_000_000_000L (* 2s after exchange ts; default threshold 1s *)
      ~bid:99.0 ~ask:101.0 ~sequence:(Some 1L) in
    match v with Drop_stale _ -> () | _ -> Alcotest.fail "expected Drop_stale"


let test_trade_gap_detected () =
  let dq = DQ.create ~exchange:"test" () in
  let _ =
    DQ.check_trade_print dq ~symbol:"BTC" ~exchange_ts_ns:100L ~ingest_ts_ns:100L
      ~sequence:(Some 5L) in
  let v =
    DQ.check_trade_print dq ~symbol:"BTC" ~exchange_ts_ns:200L ~ingest_ts_ns:200L
      ~sequence:(Some 8L) in
    match v with
    | Gap_then_publish { expected; received; dropped } ->
      Alcotest.(check int64) "expected" 6L expected ;
      Alcotest.(check int64) "received" 8L received ;
      Alcotest.(check int) "dropped" 2 dropped
    | _ -> Alcotest.fail "expected Gap_then_publish"


let test_trade_out_of_order () =
  let dq = DQ.create ~exchange:"test" () in
  let _ =
    DQ.check_trade_print dq ~symbol:"BTC" ~exchange_ts_ns:100L ~ingest_ts_ns:100L
      ~sequence:(Some 10L) in
  let v =
    DQ.check_trade_print dq ~symbol:"BTC" ~exchange_ts_ns:200L ~ingest_ts_ns:200L
      ~sequence:(Some 9L) in
    match v with
    | Out_of_order ->
      let s = DQ.stats dq in
        Alcotest.(check int) "ooo counter" 1 s.out_of_order_trades
    | _ -> Alcotest.fail "expected Out_of_order"


(* What [sequence] has to be, and what happens when it is not.

   Both shipped feeds were passing something that is not a dense per-message counter, and the
   detector had no way to say so: Coinbase sent the product's full-channel sequence while the
   connector subscribes only to matches, and Binance sent the trade timestamp in milliseconds. In
   both cases every single message looked like a gap, and dropped_to_gap ran into the millions
   without anything failing. These cases pin the contract that made that possible. *)

let seq dq n =
  DQ.check_trade_print dq ~symbol:"BTC" ~exchange_ts_ns:100L ~ingest_ts_ns:100L ~sequence:(Some n)


let test_contiguous_trades_report_no_gap () =
  let dq = DQ.create ~exchange:"test" () in
    List.iter (fun n -> ignore (seq dq n)) [ 1L; 2L; 3L; 4L; 5L ] ;
    let s = DQ.stats dq in
      Alcotest.(check int) "no gaps on a dense counter" 0 s.DQ.sequence_gaps ;
      Alcotest.(check int) "and nothing counted as dropped" 0 s.DQ.dropped_to_gap


let test_none_disables_gap_detection () =
  (* The tick path passes None, because neither exchange numbers its quote updates. It previously
     passed a constant 0L, which happened to be inert only because the regression branch swallowed
     it — a magic value doing the right thing by accident. *)
  let dq = DQ.create ~exchange:"test" () in
  let v =
    DQ.check_market_tick dq ~symbol:"BTC" ~exchange_ts_ns:100L ~ingest_ts_ns:100L ~bid:99.0
      ~ask:101.0 ~sequence:None in
  let v2 =
    DQ.check_trade_print dq ~symbol:"BTC" ~exchange_ts_ns:100L ~ingest_ts_ns:100L ~sequence:None
  in
  let s = DQ.stats dq in
    Alcotest.(check bool) "tick publishes" true (v = DQ.Ok_publish) ;
    Alcotest.(check bool) "trade publishes" true (v2 = DQ.Ok_publish) ;
    Alcotest.(check int) "no gaps invented" 0 s.DQ.sequence_gaps ;
    Alcotest.(check int) "observed still counted" 2 s.DQ.total_observed


let test_a_sparse_counter_would_be_flagged_everywhere () =
  (* The failure mode itself, reproduced. Feeding a counter that advances by more than one per
     received message — a full-channel sequence, or a millisecond clock — makes every message a gap.
     This is not a bug in the detector; it is the caller breaking the contract, and the test exists
     so the shape is recognisable if a new connector does it again. *)
  let dq = DQ.create ~exchange:"test" () in
    List.iter (fun n -> ignore (seq dq n)) [ 1000L; 1275L; 1517L; 1556L ] ;
    let s = DQ.stats dq in
      Alcotest.(check int) "every message after the first looks like a gap" 3 s.DQ.sequence_gaps ;
      Alcotest.(check bool)
        (Printf.sprintf "dropped (%d) dwarfs observed (%d)" s.DQ.dropped_to_gap s.DQ.total_observed)
        true
        (s.DQ.dropped_to_gap > 100 * s.DQ.total_observed)


let _ = stats_zero

let suite =
  [
    Alcotest.test_case "ok_publish" `Quick test_ok_publish;
    Alcotest.test_case "crossed_book" `Quick test_crossed_book;
    Alcotest.test_case "stale_tick" `Quick test_stale_tick;
    Alcotest.test_case "trade_gap_detected" `Quick test_trade_gap_detected;
    Alcotest.test_case "trade_out_of_order" `Quick test_trade_out_of_order;
    Alcotest.test_case "contiguous_trades_report_no_gap" `Quick test_contiguous_trades_report_no_gap;
    Alcotest.test_case "none_disables_gap_detection" `Quick test_none_disables_gap_detection;
    Alcotest.test_case "a_sparse_counter_would_be_flagged_everywhere" `Quick
      test_a_sparse_counter_would_be_flagged_everywhere;
  ]
