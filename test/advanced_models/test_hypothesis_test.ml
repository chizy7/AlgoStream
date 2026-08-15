open Algostream_advanced_models

let make_normal ~n ~mean ~sd ~seed =
  let rng = Random.State.make [| seed |] in
    Array.init n (fun _ -> mean +. (sd *. Helpers.normal_sample rng))


let test_one_sample_t_rejects_shifted () =
  let s = make_normal ~n:200 ~mean:0.5 ~sd:1.0 ~seed:41 in
  let r = Hypothesis_test.one_sample_t ~sample:s ~mu0:0.0 in
    Alcotest.(check bool)
      (Printf.sprintf "rejects μ=0 for sample with mean 0.5 (p=%g)" r.p_value)
      true
      (Hypothesis_test.reject r ~alpha:0.05)


let test_one_sample_t_accepts_zero () =
  let s = make_normal ~n:200 ~mean:0.0 ~sd:1.0 ~seed:42 in
  let r = Hypothesis_test.one_sample_t ~sample:s ~mu0:0.0 in
    Alcotest.(check bool)
      (Printf.sprintf "does NOT reject μ=0 for centered sample (p=%g)" r.p_value)
      false
      (Hypothesis_test.reject r ~alpha:0.05)


let test_two_sample_t_welch () =
  let a = make_normal ~n:200 ~mean:0.0 ~sd:1.0 ~seed:43 in
  let b = make_normal ~n:200 ~mean:0.5 ~sd:1.0 ~seed:44 in
  let r = Hypothesis_test.two_sample_t ~sample_a:a ~sample_b:b () in
    Alcotest.(check bool)
      (Printf.sprintf "rejects equal means (p=%g)" r.p_value)
      true
      (Hypothesis_test.reject r ~alpha:0.05)


let test_ks_two_sample_same () =
  let a = make_normal ~n:200 ~mean:0.0 ~sd:1.0 ~seed:45 in
  let b = make_normal ~n:200 ~mean:0.0 ~sd:1.0 ~seed:46 in
  let r = Hypothesis_test.ks_two_sample ~sample_a:a ~sample_b:b in
    Alcotest.(check bool)
      (Printf.sprintf "does NOT reject same distribution (p=%g)" r.p_value)
      false
      (Hypothesis_test.reject r ~alpha:0.05)


let test_ks_two_sample_different () =
  let a = make_normal ~n:200 ~mean:0.0 ~sd:1.0 ~seed:47 in
  let b = make_normal ~n:200 ~mean:1.0 ~sd:1.0 ~seed:48 in
  let r = Hypothesis_test.ks_two_sample ~sample_a:a ~sample_b:b in
    Alcotest.(check bool)
      (Printf.sprintf "rejects N(0,1) vs N(1,1) (p=%g)" r.p_value)
      true
      (Hypothesis_test.reject r ~alpha:0.05)


let test_jarque_bera_uniform () =
  let rng = Random.State.make [| 49 |] in
  let s = Array.init 500 (fun _ -> Random.State.float rng 1.0) in
  let r = Hypothesis_test.jarque_bera ~sample:s in
    Alcotest.(check bool)
      (Printf.sprintf "rejects normality for uniform (p=%g)" r.p_value)
      true
      (Hypothesis_test.reject r ~alpha:0.05)


let test_jarque_bera_normal () =
  let s = make_normal ~n:500 ~mean:0.0 ~sd:1.0 ~seed:50 in
  let r = Hypothesis_test.jarque_bera ~sample:s in
    Alcotest.(check bool)
      (Printf.sprintf "does NOT reject normality for normal sample (p=%g)" r.p_value)
      false
      (Hypothesis_test.reject r ~alpha:0.01)


let test_ljung_box_white_noise () =
  let s = make_normal ~n:500 ~mean:0.0 ~sd:1.0 ~seed:51 in
  let r = Hypothesis_test.ljung_box ~residuals:s ~lags:10 in
    Alcotest.(check bool)
      (Printf.sprintf "does NOT reject no-autocorr on white noise (p=%g)" r.p_value)
      false
      (Hypothesis_test.reject r ~alpha:0.05)


let test_ljung_box_ar1 () =
  let s = Helpers.ar1_series ~n:500 ~phi:0.8 ~seed:52 in
  let r = Hypothesis_test.ljung_box ~residuals:s ~lags:10 in
    Alcotest.(check bool)
      (Printf.sprintf "rejects no-autocorr on AR(1) (p=%g)" r.p_value)
      true
      (Hypothesis_test.reject r ~alpha:0.05)


let test_chi_squared_gof_match () =
  let observed = [| 10.0; 10.0; 10.0; 10.0 |] in
  let expected = [| 10.0; 10.0; 10.0; 10.0 |] in
  let r = Hypothesis_test.chi_squared_gof ~observed ~expected in
    Alcotest.(check bool) "exact match → no reject" false (Hypothesis_test.reject r ~alpha:0.05)


let test_runs_test_runs_random () =
  (* Runs test on iid data has ~5% false-rejection rate at α=0.05; use α=0.01 and n=1000 for a
     robust always-accept under iid. *)
  let s = make_normal ~n:1000 ~mean:0.0 ~sd:1.0 ~seed:53 in
  let r = Hypothesis_test.runs_test ~sample:s in
    Alcotest.(check bool)
      (Printf.sprintf "does NOT reject randomness on iid (p=%g)" r.p_value)
      false
      (Hypothesis_test.reject r ~alpha:0.01)


let test_runs_test_rejects_pattern () =
  (* Alternating +1, -1 pattern: clearly non-random; runs = n, reject. *)
  let s = Array.init 200 (fun i -> if i mod 2 = 0 then 1.0 else -1.0) in
  let r = Hypothesis_test.runs_test ~sample:s in
    Alcotest.(check bool)
      (Printf.sprintf "rejects perfectly alternating pattern (p=%g)" r.p_value)
      true
      (Hypothesis_test.reject r ~alpha:0.05)


let suite =
  [
    Alcotest.test_case "one_sample_t_rejects_shifted" `Quick test_one_sample_t_rejects_shifted;
    Alcotest.test_case "one_sample_t_accepts_zero" `Quick test_one_sample_t_accepts_zero;
    Alcotest.test_case "two_sample_t_welch" `Quick test_two_sample_t_welch;
    Alcotest.test_case "ks_two_sample_same" `Quick test_ks_two_sample_same;
    Alcotest.test_case "ks_two_sample_different" `Quick test_ks_two_sample_different;
    Alcotest.test_case "jarque_bera_uniform" `Quick test_jarque_bera_uniform;
    Alcotest.test_case "jarque_bera_normal" `Quick test_jarque_bera_normal;
    Alcotest.test_case "ljung_box_white_noise" `Quick test_ljung_box_white_noise;
    Alcotest.test_case "ljung_box_ar1" `Quick test_ljung_box_ar1;
    Alcotest.test_case "chi_squared_gof_match" `Quick test_chi_squared_gof_match;
    Alcotest.test_case "runs_test_runs_random" `Quick test_runs_test_runs_random;
    Alcotest.test_case "runs_test_rejects_pattern" `Quick test_runs_test_rejects_pattern;
  ]
