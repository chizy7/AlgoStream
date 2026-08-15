module Quantile = Algostream_stochastic.Quantile
module Rng = Algostream_rng.Rng
module Variate = Algostream_stochastic.Variate
module Distribution = Algostream_advanced_models.Distribution

(* Type-7 quantiles on [1..10], hand-computed. h = (n-1)p, interpolating between order statistics.
   p=0.5 -> h=4.5 -> midpoint of 5 and 6 -> 5.5. p=0.25 -> h=2.25 -> 3 + 0.25*(4-3) = 3.25. *)
let ten = Array.init 10 (fun i -> float_of_int (i + 1))

let test_type7_hand_computed () =
  Alcotest.(check (float 1e-12)) "p=0 is the minimum" 1.0 (Quantile.quantile ten ~p:0.0) ;
  Alcotest.(check (float 1e-12)) "p=1 is the maximum" 10.0 (Quantile.quantile ten ~p:1.0) ;
  Alcotest.(check (float 1e-12)) "p=0.5 -> 5.5" 5.5 (Quantile.quantile ten ~p:0.5) ;
  Alcotest.(check (float 1e-12)) "p=0.25 -> 3.25" 3.25 (Quantile.quantile ten ~p:0.25) ;
  Alcotest.(check (float 1e-12)) "p=0.75 -> 7.75" 7.75 (Quantile.quantile ten ~p:0.75) ;
  Alcotest.(check (float 1e-12)) "median helper agrees" 5.5 (Quantile.median ten)


let test_clamps_out_of_range_p () =
  Alcotest.(check (float 1e-12)) "p<0 clamps to the minimum" 1.0 (Quantile.quantile ten ~p:(-0.5)) ;
  Alcotest.(check (float 1e-12)) "p>1 clamps to the maximum" 10.0 (Quantile.quantile ten ~p:1.5)


let test_single_element () =
  Alcotest.(check (float 1e-12))
    "a one-element sample is its own quantile" 42.0
    (Quantile.quantile [| 42.0 |] ~p:0.3)


let test_empty_raises () =
  Alcotest.(check bool)
    "empty sample raises" true
    (try
       ignore (Quantile.quantile [||] ~p:0.5) ;
       false
     with Invalid_argument _ -> true)


let test_does_not_mutate_input () =
  let a = [| 3.0; 1.0; 2.0 |] in
  let _ = Quantile.quantile a ~p:0.5 in
    Alcotest.(check (array (float 1e-12))) "input order untouched" [| 3.0; 1.0; 2.0 |] a


(* Against a large normal sample the empirical quantiles must track the exact normal quantiles. *)
let test_matches_normal_quantiles () =
  let rng = Rng.create ~seed:21 in
  let s = Array.init 200_000 (fun _ -> Variate.normal rng) in
    List.iter
      (fun p ->
        let empirical = Quantile.quantile s ~p in
        let exact = Distribution.Normal.quantile ~p in
          Alcotest.(check bool)
            (Printf.sprintf "p=%.2f: empirical %.4f near exact %.4f" p empirical exact)
            true
            (Float.abs (empirical -. exact) < 0.03))
      [ 0.05; 0.25; 0.5; 0.75; 0.95 ]


let test_percentile_interval_widths () =
  let rng = Rng.create ~seed:22 in
  let s = Array.init 100_000 (fun _ -> Variate.normal rng) in
  let lo95, hi95 = Quantile.percentile_interval s ~level:0.95 in
  let lo99, hi99 = Quantile.percentile_interval s ~level:0.99 in
    (* +/- 1.96 and +/- 2.576 for a standard normal. *)
    Alcotest.(check bool)
      (Printf.sprintf "95%% lower %.3f ~ -1.96" lo95)
      true
      (Float.abs (lo95 +. 1.96) < 0.05) ;
    Alcotest.(check bool)
      (Printf.sprintf "95%% upper %.3f ~ 1.96" hi95)
      true
      (Float.abs (hi95 -. 1.96) < 0.05) ;
    Alcotest.(check bool)
      "the 99% interval strictly contains the 95% one" true
      (lo99 < lo95 && hi99 > hi95)


let test_basic_interval_reflects () =
  (* basic = (2*theta - hi, 2*theta - lo): a mirror of the percentile interval about the
     estimate. *)
  let s = Array.init 1000 (fun i -> float_of_int i /. 1000.0) in
  let p_lo, p_hi = Quantile.percentile_interval s ~level:0.95 in
  let b_lo, b_hi = Quantile.basic_interval s ~point_estimate:0.5 ~level:0.95 in
    Alcotest.(check (float 1e-9)) "lower is the reflected upper" (1.0 -. p_hi) b_lo ;
    Alcotest.(check (float 1e-9)) "upper is the reflected lower" (1.0 -. p_lo) b_hi


let test_bca_falls_back_gracefully () =
  (* Degenerate inputs must produce an interval rather than nan. *)
  let s = Array.make 100 1.0 in
  let lo, hi = Quantile.bca s ~point_estimate:1.0 ~jackknife:[| 1.0; 1.0 |] ~level:0.95 in
    Alcotest.(check bool)
      "finite bounds on a degenerate sample" true
      (Float.is_finite lo && Float.is_finite hi)


let test_bca_brackets_the_estimate_on_skewed_data () =
  let rng = Rng.create ~seed:23 in
  (* Lognormal is strongly right-skewed, which is where BCa earns its keep. *)
  let s = Array.init 5000 (fun _ -> Variate.lognormal rng ~mu:0.0 ~sigma:0.8) in
  let point = Quantile.median s in
  let jack = Array.sub s 0 500 in
  let lo, hi = Quantile.bca s ~point_estimate:point ~jackknife:jack ~level:0.95 in
    Alcotest.(check bool)
      (Printf.sprintf "BCa interval [%.4f, %.4f] brackets the estimate %.4f" lo hi point)
      true
      (lo <= point && point <= hi)


(* The number that makes a 99% interval honest: the tail has far fewer observations, so its quantile
   estimate is less certain than the 95% one. *)
let test_mc_standard_error_is_larger_in_the_tail () =
  let rng = Rng.create ~seed:24 in
  let s = Array.init 10_000 (fun _ -> Variate.normal rng) in
  let se50 = Quantile.mc_standard_error s ~p:0.50 in
  let se95 = Quantile.mc_standard_error s ~p:0.95 in
  let se99 = Quantile.mc_standard_error s ~p:0.99 in
    Alcotest.(check bool)
      (Printf.sprintf "SE grows into the tail: p50 %.5f < p95 %.5f < p99 %.5f" se50 se95 se99)
      true
      (se50 < se95 && se95 < se99)


let test_mc_standard_error_shrinks_with_n () =
  let rng = Rng.create ~seed:25 in
  let small = Array.init 1000 (fun _ -> Variate.normal rng) in
  let large = Array.init 100_000 (fun _ -> Variate.normal rng) in
    Alcotest.(check bool)
      "more runs narrows the quantile's own uncertainty" true
      (Quantile.mc_standard_error large ~p:0.95 < Quantile.mc_standard_error small ~p:0.95)


let test_summarize () =
  let rng = Rng.create ~seed:26 in
  let s = Array.init 100_000 (fun _ -> Variate.normal rng) in
  let d = Quantile.summarize s in
    Alcotest.(check int) "n" 100_000 d.Quantile.n ;
    Alcotest.(check bool)
      (Printf.sprintf "mean %.4f ~ 0" d.Quantile.mean)
      true
      (Float.abs d.Quantile.mean < 0.02) ;
    Alcotest.(check bool)
      (Printf.sprintf "sd %.4f ~ 1" d.Quantile.stddev)
      true
      (Float.abs (d.Quantile.stddev -. 1.0) < 0.02) ;
    Alcotest.(check bool)
      (Printf.sprintf "skew %.4f ~ 0" d.Quantile.skewness)
      true
      (Float.abs d.Quantile.skewness < 0.05) ;
    Alcotest.(check bool)
      (Printf.sprintf "excess kurtosis %.4f ~ 0" d.Quantile.excess_kurtosis)
      true
      (Float.abs d.Quantile.excess_kurtosis < 0.1) ;
    Alcotest.(check bool)
      (Printf.sprintf "P(<0) %.4f ~ 0.5" d.Quantile.prob_negative)
      true
      (Float.abs (d.Quantile.prob_negative -. 0.5) < 0.01) ;
    Alcotest.(check bool)
      "percentiles are ordered" true
      (d.Quantile.p01 < d.Quantile.p05 && d.Quantile.p05 < d.Quantile.p25
     && d.Quantile.p25 < d.Quantile.p50 && d.Quantile.p50 < d.Quantile.p75
     && d.Quantile.p75 < d.Quantile.p95 && d.Quantile.p95 < d.Quantile.p99)


let test_summarize_empty () =
  let d = Quantile.summarize [||] in
    Alcotest.(check int) "empty summary has n = 0" 0 d.Quantile.n


let suite =
  [
    Alcotest.test_case "type7_hand_computed" `Quick test_type7_hand_computed;
    Alcotest.test_case "clamps_out_of_range_p" `Quick test_clamps_out_of_range_p;
    Alcotest.test_case "single_element" `Quick test_single_element;
    Alcotest.test_case "empty_raises" `Quick test_empty_raises;
    Alcotest.test_case "does_not_mutate_input" `Quick test_does_not_mutate_input;
    Alcotest.test_case "matches_normal_quantiles" `Quick test_matches_normal_quantiles;
    Alcotest.test_case "percentile_interval_widths" `Quick test_percentile_interval_widths;
    Alcotest.test_case "basic_interval_reflects" `Quick test_basic_interval_reflects;
    Alcotest.test_case "bca_falls_back_gracefully" `Quick test_bca_falls_back_gracefully;
    Alcotest.test_case "bca_brackets_the_estimate_on_skewed_data" `Quick
      test_bca_brackets_the_estimate_on_skewed_data;
    Alcotest.test_case "mc_standard_error_is_larger_in_the_tail" `Quick
      test_mc_standard_error_is_larger_in_the_tail;
    Alcotest.test_case "mc_standard_error_shrinks_with_n" `Quick
      test_mc_standard_error_shrinks_with_n;
    Alcotest.test_case "summarize" `Quick test_summarize;
    Alcotest.test_case "summarize_empty" `Quick test_summarize_empty;
  ]
