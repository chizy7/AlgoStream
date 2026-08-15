module Ov = Algostream_optimization.Overfitting

(* More trials means a higher bar: the best of 1000 noise strategies beats the best of 10. If this
   were not monotone the deflated Sharpe would be useless. *)
let test_expected_max_sharpe_grows_with_trials () =
  let e n = Ov.expected_max_sharpe ~n_trials:n ~trial_sharpe_stdev:1.0 in
  let vals = List.map e [ 10; 50; 200; 1000; 5000 ] in
    ignore
      (List.fold_left
         (fun prev v ->
           Alcotest.(check bool)
             (Printf.sprintf "expected max %.4f exceeds the previous %.4f" v prev)
             true (v > prev) ;
           v)
         0.0 vals)


let test_expected_max_scales_with_stdev () =
  let a = Ov.expected_max_sharpe ~n_trials:100 ~trial_sharpe_stdev:1.0 in
  let b = Ov.expected_max_sharpe ~n_trials:100 ~trial_sharpe_stdev:2.0 in
    Alcotest.(check (float 1e-9)) "linear in the trial standard deviation" (2.0 *. a) b


(* The core claim: the same observed Sharpe becomes less credible the more configurations you
   searched to find it. *)
let test_deflated_sharpe_falls_with_trials () =
  let d n =
    Ov.deflated_sharpe_ratio ~observed_sharpe:1.5 ~n_trials:n ~trial_sharpe_stdev:0.5 ~skewness:0.0
      ~excess_kurtosis:0.0 ~n_obs:1000 in
  let few = d 5 and many = d 5000 in
    Alcotest.(check bool)
      (Printf.sprintf "5 trials gives DSR %.4f, 5000 trials gives %.4f" few many)
      true (few > many) ;
    Alcotest.(check bool)
      "and all values are probabilities" true
      (few >= 0.0 && few <= 1.0 && many >= 0.0 && many <= 1.0)


(* A Sharpe exactly at the expected maximum of the search is, by construction, no evidence at all —
   the DSR should sit near one half. *)
let test_deflated_sharpe_at_expected_max_is_near_half () =
  let n_trials = 200 in
  let sd = 0.5 in
  let e_max = Ov.expected_max_sharpe ~n_trials ~trial_sharpe_stdev:sd in
  let d =
    Ov.deflated_sharpe_ratio ~observed_sharpe:e_max ~n_trials ~trial_sharpe_stdev:sd ~skewness:0.0
      ~excess_kurtosis:0.0 ~n_obs:2000 in
    Alcotest.(check bool)
      (Printf.sprintf "DSR at the expected max is %.4f, near 0.5" d)
      true
      (Float.abs (d -. 0.5) < 0.05)


(* Lo (2002): negative skew and fat tails make a Sharpe estimate less certain, not more. *)
let test_standard_error_grows_with_fat_tails () =
  let normal = Ov.sharpe_standard_error ~sharpe:1.0 ~skewness:0.0 ~excess_kurtosis:0.0 ~n_obs:500 in
  let fat = Ov.sharpe_standard_error ~sharpe:1.0 ~skewness:0.0 ~excess_kurtosis:6.0 ~n_obs:500 in
  let skewed =
    Ov.sharpe_standard_error ~sharpe:1.0 ~skewness:(-1.5) ~excess_kurtosis:0.0 ~n_obs:500 in
    Alcotest.(check bool)
      (Printf.sprintf "excess kurtosis widens SE (%.5f > %.5f)" fat normal)
      true (fat > normal) ;
    Alcotest.(check bool)
      (Printf.sprintf "negative skew widens SE (%.5f > %.5f)" skewed normal)
      true (skewed > normal)


let test_standard_error_shrinks_with_sample () =
  let small = Ov.sharpe_standard_error ~sharpe:1.0 ~skewness:0.0 ~excess_kurtosis:0.0 ~n_obs:100 in
  let large =
    Ov.sharpe_standard_error ~sharpe:1.0 ~skewness:0.0 ~excess_kurtosis:0.0 ~n_obs:10_000 in
    Alcotest.(check bool)
      (Printf.sprintf "more observations narrows SE (%.5f < %.5f)" large small)
      true (large < small)


let test_pbo_extremes () =
  (* Every in-sample winner lands in the bottom half out of sample: total overfitting. *)
  let all_bad = Array.make 20 0.9 in
  let oos_bad = Array.make 20 0.1 in
    Alcotest.(check (float 1e-9))
      "PBO = 1 when winners always land below the OOS median" 1.0
      (Ov.probability_of_backtest_overfitting ~is_ranks:all_bad ~oos_ranks:oos_bad) ;
    let oos_good = Array.make 20 0.9 in
      Alcotest.(check (float 1e-9))
        "PBO = 0 when winners always land above it" 0.0
        (Ov.probability_of_backtest_overfitting ~is_ranks:all_bad ~oos_ranks:oos_good)


let test_minimum_backtest_length_grows_with_trials () =
  let a = Ov.minimum_backtest_length ~target_sharpe:1.0 ~n_trials:10 in
  let b = Ov.minimum_backtest_length ~target_sharpe:1.0 ~n_trials:1000 in
    Alcotest.(check bool)
      (Printf.sprintf "1000 trials needs more years (%.2f) than 10 (%.2f)" b a)
      true (b > a) ;
    (* And a stronger strategy needs less data to prove itself. *)
    let strong = Ov.minimum_backtest_length ~target_sharpe:3.0 ~n_trials:100 in
    let weak = Ov.minimum_backtest_length ~target_sharpe:0.5 ~n_trials:100 in
      Alcotest.(check bool)
        (Printf.sprintf "a Sharpe-3 strategy needs less data (%.2f) than a Sharpe-0.5 one (%.2f)"
           strong weak)
        true (strong < weak)


let test_haircut_never_negative () =
  let h = Ov.haircut_sharpe ~observed_sharpe:0.1 ~n_trials:10_000 ~trial_sharpe_stdev:1.0 in
    Alcotest.(check (float 1e-12)) "a Sharpe below the noise floor haircuts to zero" 0.0 h


let suite =
  [
    Alcotest.test_case "expected_max_sharpe_grows_with_trials" `Quick
      test_expected_max_sharpe_grows_with_trials;
    Alcotest.test_case "expected_max_scales_with_stdev" `Quick test_expected_max_scales_with_stdev;
    Alcotest.test_case "deflated_sharpe_falls_with_trials" `Quick
      test_deflated_sharpe_falls_with_trials;
    Alcotest.test_case "deflated_sharpe_at_expected_max_is_near_half" `Quick
      test_deflated_sharpe_at_expected_max_is_near_half;
    Alcotest.test_case "standard_error_grows_with_fat_tails" `Quick
      test_standard_error_grows_with_fat_tails;
    Alcotest.test_case "standard_error_shrinks_with_sample" `Quick
      test_standard_error_shrinks_with_sample;
    Alcotest.test_case "pbo_extremes" `Quick test_pbo_extremes;
    Alcotest.test_case "minimum_backtest_length_grows_with_trials" `Quick
      test_minimum_backtest_length_grows_with_trials;
    Alcotest.test_case "haircut_never_negative" `Quick test_haircut_never_negative;
  ]
