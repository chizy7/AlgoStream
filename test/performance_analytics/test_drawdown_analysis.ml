module DA = Algostream_performance.Drawdown_analysis

let day = 86_400_000_000_000L

let at i v = (Int64.mul (Int64.of_int i) day, v)

(* Three planted episodes with known depths and recovery times, plus a final unrecovered one. 100 ->
   80 -> 100 depth 20%, decline 1d, recovery 1d 100 -> 90 -> 100 depth 10%, decline 1d, recovery 1d
   100 -> 70 depth 30%, never recovers *)
let planted = [| at 0 100.0; at 1 80.0; at 2 100.0; at 3 90.0; at 4 100.0; at 5 70.0; at 6 75.0 |]

let test_episode_count_and_depths () =
  let eps = DA.episodes ~nav:planted () in
    Alcotest.(check int) "three episodes" 3 (Array.length eps) ;
    Alcotest.(check (float 1e-9)) "first is 20%" 0.20 eps.(0).DA.depth ;
    Alcotest.(check (float 1e-9)) "second is 10%" 0.10 eps.(1).DA.depth ;
    Alcotest.(check (float 1e-9)) "third is 30%" 0.30 eps.(2).DA.depth


let test_recovery_times () =
  let eps = DA.episodes ~nav:planted () in
    (match eps.(0).DA.recovery_ns with
    | Some r -> Alcotest.(check int64) "first recovers in one day" day r
    | None -> Alcotest.fail "first episode should have recovered") ;
    (match eps.(1).DA.recovery_ns with
    | Some r -> Alcotest.(check int64) "second recovers in one day" day r
    | None -> Alcotest.fail "second episode should have recovered") ;
    (* The last episode is still underwater; reporting it as recovered would understate the true
       recovery time. *)
    Alcotest.(check bool) "the final episode is unrecovered" true (eps.(2).DA.recovery_ns = None) ;
    Alcotest.(check bool) "and has no recovery timestamp" true (eps.(2).DA.recovery_ts_ns = None)


let test_max_depth_and_longest_underwater () =
  let eps = DA.episodes ~nav:planted () in
    Alcotest.(check (float 1e-9)) "deepest is 30%" 0.30 (DA.max_depth eps) ;
    Alcotest.(check bool)
      "longest underwater is positive" true
      (Int64.compare (DA.longest_underwater_ns eps) 0L > 0)


let test_min_depth_filter () =
  let eps = DA.episodes ~nav:planted ~min_depth:0.15 () in
    Alcotest.(check int) "the 10% episode is filtered out" 2 (Array.length eps)


let test_recovery_statistics () =
  let eps = DA.episodes ~nav:planted () in
    Alcotest.(check (float 1e-9)) "two of three recovered" (2.0 /. 3.0) (DA.recovery_rate eps) ;
    (match DA.mean_recovery_ns eps with
    | Some m -> Alcotest.(check int64) "mean over recovered episodes only" day m
    | None -> Alcotest.fail "expected a mean") ;
    match DA.median_recovery_ns eps with
    | Some m -> Alcotest.(check int64) "median" day m
    | None -> Alcotest.fail "expected a median"


let test_worst_sorts_by_depth () =
  let eps = DA.episodes ~nav:planted () in
  let w = DA.worst eps ~n:2 in
    Alcotest.(check int) "two returned" 2 (Array.length w) ;
    Alcotest.(check (float 1e-9)) "deepest first" 0.30 w.(0).DA.depth ;
    Alcotest.(check (float 1e-9)) "then the next" 0.20 w.(1).DA.depth


let test_monotone_curve_has_no_episodes () =
  let up = Array.init 10 (fun i -> at i (100.0 +. float_of_int i)) in
    Alcotest.(check int)
      "a curve that only rises has no drawdowns" 0
      (Array.length (DA.episodes ~nav:up ())) ;
    Alcotest.(check (float 1e-12)) "and zero max depth" 0.0 (DA.max_depth (DA.episodes ~nav:up ()))


let test_underwater_curve () =
  let uw = DA.underwater_curve ~nav:planted in
    Alcotest.(check int) "same length as the NAV curve" (Array.length planted) (Array.length uw) ;
    Alcotest.(check (float 1e-12)) "at the peak, zero" 0.0 (snd uw.(0)) ;
    Alcotest.(check (float 1e-12)) "at the first trough, 20%" 0.20 (snd uw.(1))


let test_ulcer_and_pain_index () =
  let ulcer = DA.ulcer_index ~nav:planted in
  let pain = DA.pain_index ~nav:planted in
    Alcotest.(check bool) (Printf.sprintf "ulcer index %.3f is positive" ulcer) true (ulcer > 0.0) ;
    Alcotest.(check bool) (Printf.sprintf "pain index %.4f is positive" pain) true (pain > 0.0) ;
    (* A deeper, longer drawdown must raise both. *)
    let worse = [| at 0 100.0; at 1 50.0; at 2 50.0; at 3 50.0 |] in
      Alcotest.(check bool)
        "a deeper sustained drawdown raises the ulcer index" true
        (DA.ulcer_index ~nav:worse > ulcer)


let test_short_curves () =
  Alcotest.(check int) "empty" 0 (Array.length (DA.episodes ~nav:[||] ())) ;
  Alcotest.(check int) "single point" 0 (Array.length (DA.episodes ~nav:[| at 0 100.0 |] ()))


let suite =
  [
    Alcotest.test_case "episode_count_and_depths" `Quick test_episode_count_and_depths;
    Alcotest.test_case "recovery_times" `Quick test_recovery_times;
    Alcotest.test_case "max_depth_and_longest_underwater" `Quick
      test_max_depth_and_longest_underwater;
    Alcotest.test_case "min_depth_filter" `Quick test_min_depth_filter;
    Alcotest.test_case "recovery_statistics" `Quick test_recovery_statistics;
    Alcotest.test_case "worst_sorts_by_depth" `Quick test_worst_sorts_by_depth;
    Alcotest.test_case "monotone_curve_has_no_episodes" `Quick test_monotone_curve_has_no_episodes;
    Alcotest.test_case "underwater_curve" `Quick test_underwater_curve;
    Alcotest.test_case "ulcer_and_pain_index" `Quick test_ulcer_and_pain_index;
    Alcotest.test_case "short_curves" `Quick test_short_curves;
  ]
