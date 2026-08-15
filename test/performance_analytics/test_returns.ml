module Returns = Algostream_performance.Returns

let day = 86_400_000_000_000L

let nav_of vals = Array.mapi (fun i v -> (Int64.mul (Int64.of_int i) day, v)) vals

let test_simple_returns_hand_computed () =
  let nav = nav_of [| 100.0; 110.0; 99.0 |] in
  let r = Returns.of_nav ~nav ~kind:Returns.Simple in
    Alcotest.(check int) "n-1 returns" 2 (Array.length r) ;
    Alcotest.(check (float 1e-12)) "110/100 - 1" 0.10 r.(0) ;
    Alcotest.(check (float 1e-12)) "99/110 - 1" (-0.10) r.(1)


let test_log_returns_are_additive () =
  let nav = nav_of [| 100.0; 110.0; 121.0 |] in
  let r = Returns.of_nav ~nav ~kind:Returns.Log in
  let total = Array.fold_left ( +. ) 0.0 r in
    Alcotest.(check (float 1e-12)) "log returns sum to log(121/100)" (log 1.21) total


(* An equity curve that reaches zero has no meaningful return afterwards. Terminating beats emitting
   nan, which would silently poison every downstream metric. *)
let test_non_positive_equity_terminates_the_series () =
  let nav = nav_of [| 100.0; 50.0; 0.0; 10.0 |] in
  let r = Returns.of_nav ~nav ~kind:Returns.Simple in
    Alcotest.(check int) "series stops at the zero crossing" 1 (Array.length r) ;
    Alcotest.(check bool) "and contains no nan" true (Array.for_all Float.is_finite r)


let test_short_curves () =
  Alcotest.(check int) "empty" 0 (Array.length (Returns.of_nav ~nav:[||] ~kind:Returns.Simple)) ;
  Alcotest.(check int)
    "single point" 0
    (Array.length (Returns.of_nav ~nav:(nav_of [| 100.0 |]) ~kind:Returns.Simple))


(* Median, not mean: one weekend gap must not redefine the sampling cadence. *)
let test_infer_interval_uses_the_median () =
  let ts = [| 0L; day; Int64.mul day 2L; Int64.mul day 100L |] in
  let nav = Array.mapi (fun i t -> (t, 100.0 +. float_of_int i)) ts in
    Alcotest.(check int64)
      "one long gap does not move the median" day (Returns.infer_interval_ns ~nav)


let test_periods_per_year () =
  Alcotest.(check (float 1e-6))
    "daily on a 24/7 calendar" 365.0
    (Returns.periods_per_year ~interval_ns:day ()) ;
  Alcotest.(check (float 1e-6))
    "daily on a 252-day calendar" 252.0
    (Returns.periods_per_year ~days_per_year:252.0 ~interval_ns:day ()) ;
  Alcotest.(check (float 1e-6))
    "hourly, 24/7" (365.0 *. 24.0)
    (Returns.periods_per_year ~interval_ns:3_600_000_000_000L ()) ;
  Alcotest.(check (float 1e-9))
    "a non-positive interval yields 0" 0.0
    (Returns.periods_per_year ~interval_ns:0L ())


let test_per_period_rate_compounds () =
  let ppy = 252.0 in
  let r = Returns.per_period_rate ~annual_rate:0.05 ~periods_per_year:ppy in
    Alcotest.(check (float 1e-9))
      "compounds back to the annual rate" 0.05
      (((1.0 +. r) ** ppy) -. 1.0)


let test_excess_subtracts_the_risk_free_rate () =
  let returns = [| 0.01; 0.02 |] in
  let ppy = 252.0 in
  let e = Returns.excess ~returns ~risk_free_rate_ann:0.05 ~periods_per_year:ppy in
  let rf = Returns.per_period_rate ~annual_rate:0.05 ~periods_per_year:ppy in
    Alcotest.(check (float 1e-12)) "first" (0.01 -. rf) e.(0) ;
    Alcotest.(check (float 1e-12)) "second" (0.02 -. rf) e.(1)


let test_total_return () =
  Alcotest.(check (float 1e-12))
    "simple compounds" 0.21
    (Returns.total_return ~returns:[| 0.1; 0.1 |] ~kind:Returns.Simple) ;
  Alcotest.(check (float 1e-12))
    "log exponentiates"
    (exp 0.2 -. 1.0)
    (Returns.total_return ~returns:[| 0.1; 0.1 |] ~kind:Returns.Log)


let test_stddev_uses_n_minus_1 () =
  (* [1;2;3;4]: mean 2.5, sum sq dev 5, /3 = 1.6667, sqrt = 1.29099 *)
  Alcotest.(check (float 1e-5))
    "sample standard deviation" 1.29099
    (Returns.stddev [| 1.0; 2.0; 3.0; 4.0 |]) ;
  Alcotest.(check (float 1e-12))
    "fewer than two observations gives 0" 0.0 (Returns.stddev [| 5.0 |])


(* The single largest source of Sortino disagreement between tools: the full-sample n denominator,
   with above-MAR observations contributing zero rather than being excluded. *)
let test_downside_deviation_uses_full_sample_n () =
  let returns = [| -0.02; 0.05; -0.01; 0.03 |] in
  let dd = Returns.downside_deviation ~returns ~mar:0.0 in
    (* sum of squares below MAR = 0.0004 + 0.0001 = 0.0005; divided by 4 (not 2) = 0.000125 *)
    Alcotest.(check (float 1e-9)) "divides by the full sample size" (sqrt 0.000125) dd ;
    (* If it excluded the upside observations it would divide by 2 and give a larger figure. *)
    Alcotest.(check bool)
      "which is smaller than the exclude-upside convention" true
      (dd < sqrt 0.00025)


let test_downside_deviation_zero_when_never_below_mar () =
  Alcotest.(check (float 1e-12))
    "all returns above MAR" 0.0
    (Returns.downside_deviation ~returns:[| 0.01; 0.02 |] ~mar:0.0)


let suite =
  [
    Alcotest.test_case "simple_returns_hand_computed" `Quick test_simple_returns_hand_computed;
    Alcotest.test_case "log_returns_are_additive" `Quick test_log_returns_are_additive;
    Alcotest.test_case "non_positive_equity_terminates_the_series" `Quick
      test_non_positive_equity_terminates_the_series;
    Alcotest.test_case "short_curves" `Quick test_short_curves;
    Alcotest.test_case "infer_interval_uses_the_median" `Quick test_infer_interval_uses_the_median;
    Alcotest.test_case "periods_per_year" `Quick test_periods_per_year;
    Alcotest.test_case "per_period_rate_compounds" `Quick test_per_period_rate_compounds;
    Alcotest.test_case "excess_subtracts_the_risk_free_rate" `Quick
      test_excess_subtracts_the_risk_free_rate;
    Alcotest.test_case "total_return" `Quick test_total_return;
    Alcotest.test_case "stddev_uses_n_minus_1" `Quick test_stddev_uses_n_minus_1;
    Alcotest.test_case "downside_deviation_uses_full_sample_n" `Quick
      test_downside_deviation_uses_full_sample_n;
    Alcotest.test_case "downside_deviation_zero_when_never_below_mar" `Quick
      test_downside_deviation_zero_when_never_below_mar;
  ]
