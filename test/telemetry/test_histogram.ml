module H = Algostream_telemetry.Histogram

let of_list vs =
  let h = H.create () in
    List.iter (fun v -> H.record h (Int64.of_int v)) vs ;
    h


(* Below 2^sub_bits every value gets its own bucket, so the histogram is exact there. *)
let test_exact_in_linear_region () =
  let h = of_list [ 0; 1; 2; 3; 4; 5; 6; 7; 8; 9 ] in
    Alcotest.(check int64) "count" 10L (H.count h) ;
    Alcotest.(check int64) "sum" 45L (H.sum h) ;
    Alcotest.(check int64) "max" 9L (H.max h) ;
    Alcotest.(check int64) "p100 is the largest sample" 9L (H.percentile h 100.0) ;
    Alcotest.(check int64) "p0 is the smallest sample" 0L (H.percentile h 0.0)


(* Above the linear region a value is reported to within 2^-sub_bits relative error. Assert the
   bound holds for every value across several octaves, and that the report is never an
   under-estimate — a latency histogram that flatters itself is worse than none. *)
let test_relative_error_bound () =
  let tolerance = 1.0 /. float_of_int (1 lsl H.sub_bits) in
  let worst = ref 0.0 in
    for v = 1 to 200_000 do
      let h = H.create () in
        H.record h (Int64.of_int v) ;
        let reported = Int64.to_int (H.percentile h 50.0) in
          if reported < v then
            Alcotest.failf "value %d reported as %d — histogram must never under-report" v reported ;
          let err = float_of_int (reported - v) /. float_of_int v in
            if err > !worst then worst := err
    done ;
    Alcotest.(check bool)
      (Printf.sprintf "worst relative error %.4f <= %.4f" !worst tolerance)
      true (!worst <= tolerance)


let test_percentiles_on_uniform () =
  (* 1..1000 uniformly: the p-th percentile should land near p*10. *)
  let h = of_list (List.init 1000 (fun i -> i + 1)) in
  let check p expected =
    let got = Int64.to_int (H.percentile h p) in
    let err = abs (got - expected) in
      Alcotest.(check bool)
        (Printf.sprintf "p%.1f = %d, expected ~%d (err %d)" p got expected err)
        true
        (err <= expected / 10) in
    check 50.0 500 ;
    check 90.0 900 ;
    check 99.0 990 ;
    Alcotest.(check int64) "count" 1000L (H.count h)


let test_count_at_or_above () =
  let h = of_list (List.init 100 (fun i -> i + 1)) in
  (* Buckets are coarse up here, so assert a range rather than an exact split. *)
  let n = Int64.to_int (H.count_at_or_above h 50L) in
    Alcotest.(check bool)
      (Printf.sprintf "roughly half at or above 50 (got %d)" n)
      true
      (n >= 45 && n <= 56) ;
    Alcotest.(check int64) "everything is >= 0" 100L (H.count_at_or_above h 0L) ;
    Alcotest.(check int64) "nothing is >= 10^9" 0L (H.count_at_or_above h 1_000_000_000L)


let test_negative_is_rejected () =
  let h = H.create () in
    H.record h (-5L) ;
    H.record h 10L ;
    Alcotest.(check int64) "negative sample ignored" 1L (H.count h) ;
    Alcotest.(check int64) "sum unaffected by the negative" 10L (H.sum h)


let test_empty_and_reset () =
  let h = H.create () in
    Alcotest.(check int64) "empty count" 0L (H.count h) ;
    Alcotest.(check int64) "empty percentile" 0L (H.percentile h 99.0) ;
    Alcotest.(check (float 0.0)) "empty mean" 0.0 (H.mean h) ;
    H.record h 100L ;
    H.reset h ;
    Alcotest.(check int64) "count after reset" 0L (H.count h) ;
    Alcotest.(check int64) "max after reset" 0L (H.max h)


let test_percentile_rejects_bad_p () =
  let h = of_list [ 1; 2; 3 ] in
    Alcotest.check_raises "p > 100" (Invalid_argument "Histogram.percentile: p must be in [0, 100]")
      (fun () -> ignore (H.percentile h 101.0)) ;
    Alcotest.check_raises "p < 0" (Invalid_argument "Histogram.percentile: p must be in [0, 100]")
      (fun () -> ignore (H.percentile h (-1.0)))


(* The regression test for the data race this module was written to remove.

   The bus records Publish_to_enqueue from every producer Domain while the dispatcher records the
   other three phases, all into a Queue.t guarded by nothing. Against the old LatencyMonitor this
   loses samples (or segfaults); against an array of atomics the total must be exact. *)
let test_concurrent_producers_lose_nothing () =
  let h = H.create () in
  let n_domains = 8 and per_domain = 20_000 in
  let worker () =
    for i = 1 to per_domain do
      H.record h (Int64.of_int (i land 0xFFFF))
    done in
  let domains = Array.init (n_domains - 1) (fun _ -> Domain.spawn worker) in
    worker () ;
    Array.iter Domain.join domains ;
    Alcotest.(check int64)
      (Printf.sprintf "%d domains x %d samples all recorded" n_domains per_domain)
      (Int64.of_int (n_domains * per_domain))
      (H.count h)


let test_summary_shape () =
  let h = of_list (List.init 500 (fun i -> (i * 7) + 1)) in
  let s = H.summary h in
    Alcotest.(check int64) "summary count" 500L s.H.count ;
    Alcotest.(check bool) "p50 <= p99" true (Int64.compare s.H.p50_ns s.H.p99_ns <= 0) ;
    Alcotest.(check bool) "p99 <= p99.9" true (Int64.compare s.H.p99_ns s.H.p999_ns <= 0) ;
    Alcotest.(check bool) "p99.9 <= max" true (Int64.compare s.H.p999_ns s.H.max_ns <= 0) ;
    Alcotest.(check bool) "mean is positive" true (s.H.mean_ns > 0.0)


let suite =
  [
    Alcotest.test_case "exact_in_linear_region" `Quick test_exact_in_linear_region;
    Alcotest.test_case "relative_error_bound" `Quick test_relative_error_bound;
    Alcotest.test_case "percentiles_on_uniform" `Quick test_percentiles_on_uniform;
    Alcotest.test_case "count_at_or_above" `Quick test_count_at_or_above;
    Alcotest.test_case "negative_is_rejected" `Quick test_negative_is_rejected;
    Alcotest.test_case "empty_and_reset" `Quick test_empty_and_reset;
    Alcotest.test_case "percentile_rejects_bad_p" `Quick test_percentile_rejects_bad_p;
    Alcotest.test_case "concurrent_producers_lose_nothing" `Quick
      test_concurrent_producers_lose_nothing;
    Alcotest.test_case "summary_shape" `Quick test_summary_shape;
  ]
