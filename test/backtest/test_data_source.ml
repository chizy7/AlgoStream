module BT = Algostream_backtest
open Helpers

let test_of_records_sorts_by_time () =
  let unsorted =
    [|
      quoted_tick ~i:5 ~price:105.0 ();
      quoted_tick ~i:1 ~price:101.0 ();
      quoted_tick ~i:3 ~price:103.0 ();
    |] in
  let ds = BT.Data_source.of_records unsorted in
  let seen = ref [] in
  let n = BT.Data_source.iter ds ~f:(fun r -> seen := BT.Data_source.ts_ns r :: !seen) in
    Alcotest.(check int) "all three delivered" 3 n ;
    Alcotest.(check (list int64))
      "delivered in ascending time order"
      [ ts_of 1; ts_of 3; ts_of 5 ]
      (List.rev !seen) ;
    Alcotest.(check int) "nothing dropped" 0 (BT.Data_source.out_of_order_dropped ds)


(* Records sharing a timestamp must keep their input order — this is what makes a synthetic
   multi-symbol path reproducible. *)
let test_stable_within_same_timestamp () =
  let same =
    [|
      quoted_tick ~symbol:"A" ~i:1 ~price:1.0 ();
      quoted_tick ~symbol:"B" ~i:1 ~price:2.0 ();
      quoted_tick ~symbol:"C" ~i:1 ~price:3.0 ();
    |] in
  let order () =
    let ds = BT.Data_source.of_records same in
    let seen = ref [] in
    let _ = BT.Data_source.iter ds ~f:(fun r -> seen := BT.Data_source.symbol r :: !seen) in
      List.rev !seen in
    Alcotest.(check (list string)) "input order preserved" [ "A"; "B"; "C" ] (order ()) ;
    Alcotest.(check (list string)) "and is stable across calls" (order ()) (order ())


let test_of_bars () =
  let bars =
    Array.init 3 (fun i ->
      {
        Algostream_time_series.Bar.symbol = "TEST";
        open_ts = ts_of i;
        close_ts = ts_of (i + 1);
        open_ = 100.0;
        high = 101.0;
        low = 99.0;
        close = 100.5 +. float_of_int i;
        volume = 10.0;
        n_ticks = 5;
        partial = false;
      }) in
  let ds = BT.Data_source.of_bars bars in
  let prices = ref [] in
  let n =
    BT.Data_source.iter ds ~f:(fun r ->
      match r with BT.Data_source.Tick t -> prices := t.price :: !prices | _ -> ()) in
    Alcotest.(check int) "one tick per bar" 3 n ;
    Alcotest.(check (list (float 1e-9)))
      "priced at the bar close" [ 100.5; 101.5; 102.5 ] (List.rev !prices)


let test_symbols () =
  let recs =
    [|
      quoted_tick ~symbol:"BTC" ~i:1 ~price:1.0 ();
      quoted_tick ~symbol:"ETH" ~i:2 ~price:2.0 ();
      quoted_tick ~symbol:"BTC" ~i:3 ~price:3.0 ();
    |] in
  let ds = BT.Data_source.of_records recs in
    Alcotest.(check (list string))
      "distinct, first-seen order" [ "BTC"; "ETH" ] (BT.Data_source.symbols ds)


let test_concat_preserves_order () =
  let a = BT.Data_source.of_records [| quoted_tick ~i:1 ~price:1.0 () |] in
  let b = BT.Data_source.of_records [| quoted_tick ~i:2 ~price:2.0 () |] in
  let c = BT.Data_source.concat [ a; b ] in
  let seen = ref [] in
  let n = BT.Data_source.iter c ~f:(fun r -> seen := BT.Data_source.ts_ns r :: !seen) in
    Alcotest.(check int) "both delivered" 2 n ;
    Alcotest.(check (list int64)) "in order" [ ts_of 1; ts_of 2 ] (List.rev !seen)


let suite =
  [
    Alcotest.test_case "of_records_sorts_by_time" `Quick test_of_records_sorts_by_time;
    Alcotest.test_case "stable_within_same_timestamp" `Quick test_stable_within_same_timestamp;
    Alcotest.test_case "of_bars" `Quick test_of_bars;
    Alcotest.test_case "symbols" `Quick test_symbols;
    Alcotest.test_case "concat_preserves_order" `Quick test_concat_preserves_order;
  ]
