module BC = Algostream_performance.Benchmark_compare
module Ols = Algostream_pairs.Ols
module Rng = Algostream_rng.Rng
module Variate = Algostream_stochastic.Variate

let ppy = 252.0

let test_identical_series_gives_beta_one_alpha_zero () =
  let rng = Rng.create ~seed:1 in
  let b = Array.init 1000 (fun _ -> 0.0005 +. (0.01 *. Variate.normal rng)) in
  let r = BC.compare ~strategy:b ~benchmark:b ~periods_per_year:ppy () in
    Alcotest.(check (float 1e-9)) "beta = 1" 1.0 r.BC.beta ;
    Alcotest.(check (float 1e-9)) "alpha = 0" 0.0 r.BC.alpha_ann ;
    Alcotest.(check (float 1e-9)) "R^2 = 1" 1.0 r.BC.r_squared ;
    Alcotest.(check (float 1e-9)) "correlation = 1" 1.0 r.BC.correlation ;
    Alcotest.(check (float 1e-9)) "tracking error = 0" 0.0 r.BC.tracking_error_ann


let test_doubled_series_gives_beta_two () =
  let rng = Rng.create ~seed:2 in
  let b = Array.init 1000 (fun _ -> 0.01 *. Variate.normal rng) in
  let s = Array.map (fun x -> 2.0 *. x) b in
  let r = BC.compare ~strategy:s ~benchmark:b ~periods_per_year:ppy () in
    Alcotest.(check (float 1e-9)) "beta = 2" 2.0 r.BC.beta ;
    Alcotest.(check (float 1e-9)) "alpha still 0" 0.0 r.BC.alpha_ann


let test_constant_alpha_is_recovered () =
  let rng = Rng.create ~seed:3 in
  let b = Array.init 2000 (fun _ -> 0.01 *. Variate.normal rng) in
  let excess = 0.0004 in
  let s = Array.map (fun x -> x +. excess) b in
  let r = BC.compare ~strategy:s ~benchmark:b ~periods_per_year:ppy () in
    Alcotest.(check (float 1e-6)) "annualized alpha" (excess *. ppy) r.BC.alpha_ann


(* The inline OLS exists to avoid dragging algostream_pairs (and transitively the event bus) into a
   metrics library that a Monte Carlo worker links per run. Cross-check it against the real one. *)
let test_inline_ols_agrees_with_pairs_ols () =
  let rng = Rng.create ~seed:4 in
  let b = Array.init 1000 (fun _ -> 0.01 *. Variate.normal rng) in
  let s =
    Array.mapi
      (fun i x -> (1.7 *. x) +. 0.0002 +. (0.002 *. Variate.normal rng) +. (0.0 *. float_of_int i))
      b in
  let r = BC.compare ~strategy:s ~benchmark:b ~periods_per_year:ppy () in
    match Ols.regress2 ~x:b ~y:s with
    | Error _ -> Alcotest.fail "Ols.regress2 failed"
    | Ok (_intercept, slope, _r2) ->
      Alcotest.(check (float 1e-10)) "beta matches Pairs.Ols.regress2 slope" slope r.BC.beta


let test_capture_ratios () =
  (* Strategy captures all of the upside and half of the downside: up 1.0, down 0.5, ratio 2.0. *)
  let b = [| 0.02; -0.02; 0.03; -0.04 |] in
  let s = [| 0.02; -0.01; 0.03; -0.02 |] in
  let r = BC.compare ~strategy:s ~benchmark:b ~periods_per_year:ppy () in
    Alcotest.(check (float 1e-9)) "up capture = 1" 1.0 r.BC.up_capture ;
    Alcotest.(check (float 1e-9)) "down capture = 0.5" 0.5 r.BC.down_capture ;
    Alcotest.(check (float 1e-9)) "capture ratio = 2" 2.0 r.BC.capture_ratio


let test_information_ratio_and_tracking_error () =
  let rng = Rng.create ~seed:5 in
  let b = Array.init 2000 (fun _ -> 0.01 *. Variate.normal rng) in
  let s = Array.map (fun x -> x +. 0.0003) b in
  let r = BC.compare ~strategy:s ~benchmark:b ~periods_per_year:ppy () in
    (* A constant excess means zero tracking error, so the IR must be 0 rather than infinity. *)
    Alcotest.(check (float 1e-12)) "tracking error is zero" 0.0 r.BC.tracking_error_ann ;
    Alcotest.(check (float 1e-12))
      "information ratio is 0, never infinity" 0.0 r.BC.information_ratio ;
    Alcotest.(check (float 1e-6))
      "active return is the constant excess" (0.0003 *. ppy) r.BC.active_return_ann


let test_truncates_to_the_shorter_series () =
  let r =
    BC.compare ~strategy:[| 0.01; 0.02; 0.03 |] ~benchmark:[| 0.01; 0.02 |] ~periods_per_year:ppy ()
  in
    Alcotest.(check int) "uses two periods" 2 r.BC.n_periods


let test_degenerate_inputs () =
  let r = BC.compare ~strategy:[| 0.01 |] ~benchmark:[| 0.01 |] ~periods_per_year:ppy () in
    Alcotest.(check int) "too short returns the empty record" 0 r.BC.n_periods


let suite =
  [
    Alcotest.test_case "identical_series_gives_beta_one_alpha_zero" `Quick
      test_identical_series_gives_beta_one_alpha_zero;
    Alcotest.test_case "doubled_series_gives_beta_two" `Quick test_doubled_series_gives_beta_two;
    Alcotest.test_case "constant_alpha_is_recovered" `Quick test_constant_alpha_is_recovered;
    Alcotest.test_case "inline_ols_agrees_with_pairs_ols" `Quick
      test_inline_ols_agrees_with_pairs_ols;
    Alcotest.test_case "capture_ratios" `Quick test_capture_ratios;
    Alcotest.test_case "information_ratio_and_tracking_error" `Quick
      test_information_ratio_and_tracking_error;
    Alcotest.test_case "truncates_to_the_shorter_series" `Quick test_truncates_to_the_shorter_series;
    Alcotest.test_case "degenerate_inputs" `Quick test_degenerate_inputs;
  ]
