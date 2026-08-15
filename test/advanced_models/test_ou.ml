open Algostream_advanced_models

let test_recovers_known_params () =
  let true_p = { Ornstein_uhlenbeck.theta = 0.5; mu = 0.0; sigma = 1.0 } in
  let dt = 0.1 in
  let series = Ornstein_uhlenbeck.simulate true_p ~n:2048 ~dt ~seed:61 ~r0:0.0 in
    match Ornstein_uhlenbeck.fit ~series ~dt with
    | Error _ -> Alcotest.fail "OU fit failed"
    | Ok r ->
      Alcotest.(check bool)
        (Printf.sprintf "θ=%g within ±30%% of 0.5" r.params.theta)
        true
        (abs_float (r.params.theta -. 0.5) < 0.15) ;
      Alcotest.(check bool)
        (Printf.sprintf "μ=%g within ±0.2 of 0" r.params.mu)
        true
        (abs_float r.params.mu < 0.2) ;
      let expected_hl = log 2.0 /. 0.5 in
        Alcotest.(check bool)
          (Printf.sprintf "half_life=%g near %g" r.half_life expected_hl)
          true
          (abs_float (r.half_life -. expected_hl) /. expected_hl < 0.4)


let test_random_walk_non_reverting () =
  let series = Helpers.random_walk_series ~n:1024 ~seed:62 in
    match Ornstein_uhlenbeck.fit ~series ~dt:1.0 with
    | Error `Non_reverting -> ()
    | Ok r ->
      (* Random walk could occasionally fit a tiny θ; require very long half-life *)
      Alcotest.(check bool)
        (Printf.sprintf "random walk should not show fast reversion; hl=%g" r.half_life)
        true (r.half_life > 100.0)
    | Error _ -> Alcotest.fail "unexpected error"


let test_expected_value_and_variance () =
  let p = { Ornstein_uhlenbeck.theta = 1.0; mu = 5.0; sigma = 2.0 } in
  (* E[r_t | r_0] → μ as t → ∞ *)
  let ev_far = Ornstein_uhlenbeck.expected_value p ~r0:0.0 ~t:100.0 in
    Alcotest.(check (float 1e-6)) "E → μ" 5.0 ev_far ;
    (* Var → σ²/(2θ) *)
    let var_far = Ornstein_uhlenbeck.expected_variance p ~t:100.0 in
    let stationary_var = p.sigma *. p.sigma /. (2.0 *. p.theta) in
      Alcotest.(check (float 1e-6)) "Var → σ²/(2θ)" stationary_var var_far


let suite =
  [
    Alcotest.test_case "recovers_known_params" `Quick test_recovers_known_params;
    Alcotest.test_case "random_walk_non_reverting" `Quick test_random_walk_non_reverting;
    Alcotest.test_case "expected_value_and_variance" `Quick test_expected_value_and_variance;
  ]
