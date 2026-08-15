module BB = Algostream_time_series.Bar_builder
module Bar = Algostream_time_series.Bar

let interval = 1_000_000_000L (* 1s *)

let test_first_tick_no_emit () =
  let bb = BB.create ~symbol:"BTC" ~interval_ns:interval in
  let r = BB.on_tick bb ~ts:0L ~price:100.0 ~size:1.0 in
    Alcotest.(check bool) "no emit on first tick" true (Option.is_none r)


let test_emits_at_boundary () =
  let bb = BB.create ~symbol:"BTC" ~interval_ns:interval in
  let _ = BB.on_tick bb ~ts:0L ~price:100.0 ~size:1.0 in
  let _ = BB.on_tick bb ~ts:500_000_000L ~price:101.0 ~size:2.0 in
  let r = BB.on_tick bb ~ts:1_000_000_000L ~price:102.0 ~size:3.0 in
    match r with
    | Some bar ->
      Alcotest.(check int64) "open_ts" 0L bar.Bar.open_ts ;
      Alcotest.(check int64) "close_ts" 1_000_000_000L bar.close_ts ;
      Alcotest.(check (float 1e-9)) "open" 100.0 bar.open_ ;
      Alcotest.(check (float 1e-9)) "high" 101.0 bar.high ;
      Alcotest.(check (float 1e-9)) "low" 100.0 bar.low ;
      Alcotest.(check (float 1e-9)) "close" 101.0 bar.close ;
      Alcotest.(check (float 1e-9)) "volume" 3.0 bar.volume ;
      Alcotest.(check int) "n_ticks" 2 bar.n_ticks ;
      Alcotest.(check bool) "not partial" false bar.partial
    | None -> Alcotest.fail "expected bar emission at boundary"


let test_close_ts_belongs_to_next_bar () =
  let bb = BB.create ~symbol:"BTC" ~interval_ns:interval in
  let _ = BB.on_tick bb ~ts:0L ~price:100.0 ~size:1.0 in
  let r = BB.on_tick bb ~ts:1_000_000_000L ~price:200.0 ~size:1.0 in
    match r with
    | Some bar ->
      (* the price=200 tick lands in the NEXT bar; the emitted bar's close should reflect price
         100 *)
      Alcotest.(check (float 1e-9)) "emitted close not 200" 100.0 bar.close
    | None -> Alcotest.fail "expected bar emission"


let test_late_tick_dropped () =
  let bb = BB.create ~symbol:"BTC" ~interval_ns:interval in
  let _ = BB.on_tick bb ~ts:5_000_000_000L ~price:100.0 ~size:1.0 in
  let r = BB.on_tick bb ~ts:1_000_000_000L ~price:50.0 ~size:1.0 in
    Alcotest.(check bool) "no emit on late tick" true (Option.is_none r) ;
    Alcotest.(check int) "late counter" 1 (BB.late_tick_count bb)


let test_flush_returns_partial () =
  let bb = BB.create ~symbol:"BTC" ~interval_ns:interval in
  let _ = BB.on_tick bb ~ts:0L ~price:100.0 ~size:1.0 in
  let _ = BB.on_tick bb ~ts:500_000_000L ~price:101.0 ~size:2.0 in
    match BB.flush bb with
    | Some bar ->
      Alcotest.(check bool) "partial flag set" true bar.partial ;
      Alcotest.(check int) "n_ticks" 2 bar.n_ticks
    | None -> Alcotest.fail "flush should return partial bar"


let test_flush_empty () =
  let bb = BB.create ~symbol:"BTC" ~interval_ns:interval in
    Alcotest.(check bool) "no flush on empty" true (Option.is_none (BB.flush bb))


let suite =
  [
    Alcotest.test_case "first_tick_no_emit" `Quick test_first_tick_no_emit;
    Alcotest.test_case "emits_at_boundary" `Quick test_emits_at_boundary;
    Alcotest.test_case "close_ts_belongs_to_next_bar" `Quick test_close_ts_belongs_to_next_bar;
    Alcotest.test_case "late_tick_dropped" `Quick test_late_tick_dropped;
    Alcotest.test_case "flush_returns_partial" `Quick test_flush_returns_partial;
    Alcotest.test_case "flush_empty" `Quick test_flush_empty;
  ]
