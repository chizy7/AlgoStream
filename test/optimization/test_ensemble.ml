module Opt = Algostream_optimization
module En = Algostream_optimization.Ensemble
module Rng = Algostream_rng.Rng
module Variate = Algostream_stochastic.Variate

let ppy = 252.0

let member name ~sigma ~mu ~seed ~n =
  let rng = Rng.create ~seed in
    { En.name; returns = Array.init n (fun _ -> mu +. (sigma *. Variate.normal rng)) }


let test_equal_weights_sum_to_one () =
  let members =
    [|
      member "a" ~sigma:0.01 ~mu:0.0002 ~seed:1 ~n:2000;
      member "b" ~sigma:0.02 ~mu:0.0003 ~seed:2 ~n:2000;
    |] in
    match En.combine ~members ~weighting:En.Equal ~periods_per_year:ppy () with
    | Error _ -> Alcotest.fail "combine failed"
    | Ok r ->
      let total = Array.fold_left (fun a (_, w) -> a +. w) 0.0 r.En.weights in
        Alcotest.(check (float 1e-9)) "weights sum to 1" 1.0 total ;
        Array.iter (fun (_, w) -> Alcotest.(check (float 1e-9)) "each is 1/2" 0.5 w) r.En.weights


(* Inverse volatility must give the quieter member more weight — the whole point. *)
let test_inverse_volatility_favours_the_quiet_member () =
  let members =
    [|
      member "quiet" ~sigma:0.005 ~mu:0.0 ~seed:3 ~n:5000;
      member "loud" ~sigma:0.020 ~mu:0.0 ~seed:4 ~n:5000;
    |] in
    match En.combine ~members ~weighting:En.Inverse_volatility ~periods_per_year:ppy () with
    | Error _ -> Alcotest.fail "combine failed"
    | Ok r ->
      let wq = snd r.En.weights.(0) and wl = snd r.En.weights.(1) in
        Alcotest.(check bool)
          (Printf.sprintf "quiet weight %.3f exceeds loud %.3f" wq wl)
          true (wq > wl) ;
        (* 1/0.005 : 1/0.020 = 4 : 1, so roughly 0.8 / 0.2. *)
        Alcotest.(check bool)
          (Printf.sprintf "quiet weight %.3f is near 0.8" wq)
          true
          (Float.abs (wq -. 0.8) < 0.05)


(* Min-variance on a diagonal covariance has the closed form w ∝ 1/σ². *)
let test_min_variance_matches_analytic_on_diagonal () =
  let members =
    [|
      member "a" ~sigma:0.01 ~mu:0.0 ~seed:5 ~n:20_000;
      member "b" ~sigma:0.02 ~mu:0.0 ~seed:6 ~n:20_000;
    |] in
    match En.combine ~members ~weighting:En.Min_variance ~periods_per_year:ppy () with
    | Error _ -> Alcotest.fail "combine failed"
    | Ok r ->
      (* 1/0.0001 : 1/0.0004 = 4 : 1 => 0.8 / 0.2 *)
      let wa = snd r.En.weights.(0) in
        Alcotest.(check bool)
          (Printf.sprintf "min-variance weight %.3f is near the analytic 0.8" wa)
          true
          (Float.abs (wa -. 0.8) < 0.06)


(* Uncorrelated members must diversify; perfectly correlated ones cannot. *)
let test_diversification_ratio () =
  let indep =
    [|
      member "a" ~sigma:0.01 ~mu:0.0 ~seed:7 ~n:10_000;
      member "b" ~sigma:0.01 ~mu:0.0 ~seed:8 ~n:10_000;
    |] in
  let identical_returns = (member "x" ~sigma:0.01 ~mu:0.0 ~seed:9 ~n:10_000).En.returns in
  let clones =
    [|
      { En.name = "x1"; returns = identical_returns };
      { En.name = "x2"; returns = Array.copy identical_returns };
    |] in
    (match En.combine ~members:indep ~weighting:En.Equal ~periods_per_year:ppy () with
    | Error _ -> Alcotest.fail "combine failed"
    | Ok r ->
      Alcotest.(check bool)
        (Printf.sprintf "independent members diversify (ratio %.3f > 1)" r.En.diversification_ratio)
        true
        (r.En.diversification_ratio > 1.2)) ;
    match En.combine ~members:clones ~weighting:En.Equal ~periods_per_year:ppy () with
    | Error _ -> Alcotest.fail "combine failed"
    | Ok r ->
      Alcotest.(check bool)
        (Printf.sprintf "identical members do not diversify (ratio %.3f ~ 1)"
           r.En.diversification_ratio)
        true
        (Float.abs (r.En.diversification_ratio -. 1.0) < 0.01) ;
      Alcotest.(check bool)
        (Printf.sprintf "and average correlation %.3f is ~1" r.En.avg_pairwise_correlation)
        true
        (r.En.avg_pairwise_correlation > 0.99)


let test_effective_n () =
  let members =
    [|
      member "a" ~sigma:0.01 ~mu:0.0 ~seed:10 ~n:1000;
      member "b" ~sigma:0.01 ~mu:0.0 ~seed:11 ~n:1000;
      member "c" ~sigma:0.01 ~mu:0.0 ~seed:12 ~n:1000;
      member "d" ~sigma:0.01 ~mu:0.0 ~seed:13 ~n:1000;
    |] in
    match En.combine ~members ~weighting:En.Equal ~periods_per_year:ppy () with
    | Error _ -> Alcotest.fail "combine failed"
    | Ok r ->
      Alcotest.(check (float 1e-9)) "four equal weights give effective_n = 4" 4.0 r.En.effective_n


let test_empty_is_rejected () =
  match En.combine ~members:[||] ~weighting:En.Equal ~periods_per_year:ppy () with
  | Error `Empty -> Alcotest.(check bool) "empty rejected" true true
  | _ -> Alcotest.fail "expected `Empty"


let test_select_uncorrelated_drops_clones () =
  let base = (member "a" ~sigma:0.01 ~mu:0.0 ~seed:14 ~n:5000).En.returns in
  let members =
    [|
      { En.name = "a"; returns = base };
      { En.name = "a_clone"; returns = Array.copy base };
      member "b" ~sigma:0.01 ~mu:0.0 ~seed:15 ~n:5000;
    |] in
  let chosen = En.select_uncorrelated ~members ~max_corr:0.5 ~max_n:10 in
    Alcotest.(check bool)
      (Printf.sprintf "the clone is dropped (selected: %s)"
         (String.concat "," (Array.to_list chosen)))
      true
      (Array.length chosen = 2
      && Array.exists (String.equal "a") chosen
      && Array.exists (String.equal "b") chosen)


let test_rolling_combine_is_out_of_sample () =
  let members =
    [|
      member "a" ~sigma:0.01 ~mu:0.0002 ~seed:16 ~n:3000;
      member "b" ~sigma:0.015 ~mu:0.0001 ~seed:17 ~n:3000;
    |] in
    match
      En.rolling_combine ~members ~weighting:En.Min_variance ~lookback:250 ~rebalance_every:20
        ~periods_per_year:ppy ()
    with
    | Error _ -> Alcotest.fail "rolling_combine failed"
    | Ok r ->
      Alcotest.(check bool)
        "produced a finite Sharpe" true
        (Float.is_finite r.En.combined.Algostream_performance.Metrics.sharpe) ;
      Alcotest.(check bool)
        "and used fewer periods than the full sample" true
        (r.En.combined.Algostream_performance.Metrics.n_periods < 3000)


let suite =
  [
    Alcotest.test_case "equal_weights_sum_to_one" `Quick test_equal_weights_sum_to_one;
    Alcotest.test_case "inverse_volatility_favours_the_quiet_member" `Quick
      test_inverse_volatility_favours_the_quiet_member;
    Alcotest.test_case "min_variance_matches_analytic_on_diagonal" `Quick
      test_min_variance_matches_analytic_on_diagonal;
    Alcotest.test_case "diversification_ratio" `Quick test_diversification_ratio;
    Alcotest.test_case "effective_n" `Quick test_effective_n;
    Alcotest.test_case "empty_is_rejected" `Quick test_empty_is_rejected;
    Alcotest.test_case "select_uncorrelated_drops_clones" `Quick
      test_select_uncorrelated_drops_clones;
    Alcotest.test_case "rolling_combine_is_out_of_sample" `Quick
      test_rolling_combine_is_out_of_sample;
  ]
