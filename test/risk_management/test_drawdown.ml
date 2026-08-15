open Algostream_risk_management

let test_known_sequence () =
  let t = Drawdown.Tracker.create () in
  let seq = [ 100.0; 110.0; 95.0; 105.0; 80.0; 120.0 ] in
    List.iteri
      (fun i eq -> Drawdown.Tracker.update t ~equity:eq ~ts_ns:(Int64.of_int (i * 1_000_000)))
      seq ;
    Alcotest.(check (float 1e-9)) "peak = 120" 120.0 (Drawdown.Tracker.peak_equity t) ;
    Alcotest.(check (float 1e-9))
      "current_dd = 0 (at new peak)" 0.0
      (Drawdown.Tracker.current_drawdown t) ;
    (* Max DD across the sequence: 110 -> 80 = (110-80)/110 = 0.2727 *)
    Alcotest.(check (float 1e-6)) "max_dd ≈ 0.2727" 0.27272727 (Drawdown.Tracker.max_drawdown t)


let test_time_under_water () =
  let t = Drawdown.Tracker.create () in
    Drawdown.Tracker.update t ~equity:100.0 ~ts_ns:0L ;
    Drawdown.Tracker.update t ~equity:110.0 ~ts_ns:1_000_000L ;
    (* peak *)
    Drawdown.Tracker.update t ~equity:90.0 ~ts_ns:2_000_000L ;
    (* under water from here *)
    Drawdown.Tracker.update t ~equity:85.0 ~ts_ns:3_000_000L ;
    Alcotest.(check string)
      "time under water ≈ 1ms" "1000000"
      (Int64.to_string (Drawdown.Tracker.time_under_water_ns t)) ;
    (* New peak resets *)
    Drawdown.Tracker.update t ~equity:120.0 ~ts_ns:4_000_000L ;
    Alcotest.(check string)
      "time under water = 0 at new peak" "0"
      (Int64.to_string (Drawdown.Tracker.time_under_water_ns t))


let test_out_of_order_ignored () =
  let t = Drawdown.Tracker.create () in
    Drawdown.Tracker.update t ~equity:100.0 ~ts_ns:2_000_000L ;
    Drawdown.Tracker.update t ~equity:50.0 ~ts_ns:1_000_000L ;
    (* should be ignored *)
    Alcotest.(check int) "n=1 (one ignored)" 1 (Drawdown.Tracker.n_updates t) ;
    Alcotest.(check (float 1e-9)) "peak = 100 (unchanged)" 100.0 (Drawdown.Tracker.peak_equity t)


let suite =
  [
    Alcotest.test_case "known_sequence" `Quick test_known_sequence;
    Alcotest.test_case "time_under_water" `Quick test_time_under_water;
    Alcotest.test_case "out_of_order_ignored" `Quick test_out_of_order_ignored;
  ]
