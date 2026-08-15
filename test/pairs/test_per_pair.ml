open Algostream_pairs
module Bar = Algostream_time_series.Bar

let make_bar ~symbol ~open_ts ~close ~volume : Bar.t =
  {
    symbol;
    open_ts;
    close_ts = Int64.add open_ts 1_000_000_000L;
    open_ = close;
    high = close;
    low = close;
    close;
    volume;
    n_ticks = 10;
    partial = false;
  }


let test_on_tick_recovers_beta () =
  let pid = Helpers.pair "BTC" "ETH" in
  let cfg = { Config.default with beta_window = 256; spread_window = 256 } in
  let pp = Per_pair.create ~pair:pid ~config:cfg in
  let rng = Random.State.make [| 71 |] in
    for i = 0 to 511 do
      let x = Helpers.normal_sample rng +. 100.0 in
      let y = (2.0 *. x) +. (0.5 *. Helpers.normal_sample rng) in
      let ts = Int64.of_int (i * 1_000_000) in
        Per_pair.on_tick pp ~y_price:y ~x_price:x ~ts_ns:ts
    done ;
    let snap = Per_pair.snapshot pp in
      Alcotest.(check bool) "ticks counted" true (snap.n_ticks > 100) ;
      Alcotest.(check bool)
        (Printf.sprintf "beta=%g near 2" snap.beta)
        true
        (abs_float (snap.beta -. 2.0) < 0.2)


let test_out_of_order_dropped () =
  let pid = Helpers.pair "BTC" "ETH" in
  let pp = Per_pair.create ~pair:pid ~config:Config.default in
    Per_pair.on_tick pp ~y_price:100.0 ~x_price:50.0 ~ts_ns:1_000_000_000L ;
    Per_pair.on_tick pp ~y_price:101.0 ~x_price:50.5 ~ts_ns:2_000_000_000L ;
    let prev = Per_pair.out_of_order_count pp in
      Per_pair.on_tick pp ~y_price:99.0 ~x_price:49.5 ~ts_ns:500_000_000L ;
      Alcotest.(check int) "ooo + 1" (prev + 1) (Per_pair.out_of_order_count pp)


let test_on_bar_misaligned_ignored () =
  let pid = Helpers.pair "BTC" "ETH" in
  let pp = Per_pair.create ~pair:pid ~config:Config.default in
  let y_bar = make_bar ~symbol:"BTC" ~open_ts:1L ~close:100.0 ~volume:1.0 in
  let x_bar = make_bar ~symbol:"ETH" ~open_ts:2L ~close:50.0 ~volume:1.0 in
    Per_pair.on_bar pp ~y_bar ~x_bar ;
    Alcotest.(check int) "no bar processed" 0 (Per_pair.n_bars_processed pp)


let test_on_bar_aligned_processed () =
  let pid = Helpers.pair "BTC" "ETH" in
  let pp = Per_pair.create ~pair:pid ~config:Config.default in
  let y_bar = make_bar ~symbol:"BTC" ~open_ts:1L ~close:100.0 ~volume:1.0 in
  let x_bar = make_bar ~symbol:"ETH" ~open_ts:1L ~close:50.0 ~volume:1.0 in
    Per_pair.on_bar pp ~y_bar ~x_bar ;
    Alcotest.(check int) "one bar processed" 1 (Per_pair.n_bars_processed pp)


let test_on_bar_dedup () =
  let pid = Helpers.pair "BTC" "ETH" in
  let pp = Per_pair.create ~pair:pid ~config:Config.default in
  let y_bar = make_bar ~symbol:"BTC" ~open_ts:1L ~close:100.0 ~volume:1.0 in
  let x_bar = make_bar ~symbol:"ETH" ~open_ts:1L ~close:50.0 ~volume:1.0 in
    Per_pair.on_bar pp ~y_bar ~x_bar ;
    Per_pair.on_bar pp ~y_bar ~x_bar ;
    Alcotest.(check int) "deduped to one" 1 (Per_pair.n_bars_processed pp)


let suite =
  [
    Alcotest.test_case "on_tick_recovers_beta" `Quick test_on_tick_recovers_beta;
    Alcotest.test_case "out_of_order_dropped" `Quick test_out_of_order_dropped;
    Alcotest.test_case "on_bar_misaligned_ignored" `Quick test_on_bar_misaligned_ignored;
    Alcotest.test_case "on_bar_aligned_processed" `Quick test_on_bar_aligned_processed;
    Alcotest.test_case "on_bar_dedup" `Quick test_on_bar_dedup;
  ]
