module MC = Algostream_montecarlo
module Rng = Algostream_rng.Rng
module Regime = Algostream_analytics.Regime

(* A hand-built two-state chain: state 0 sticky and calm, state 3 sticky and violent. Simulating
   from it and refitting the transition matrix from the simulated labels must recover it. *)
let two_state_spec =
  let transition = Array.make_matrix 4 4 0.0 in
    (* Calm -> Calm 0.95, Calm -> Crisis 0.05; Crisis -> Crisis 0.80, Crisis -> Calm 0.20 *)
    transition.(0).(0) <- 0.95 ;
    transition.(0).(3) <- 0.05 ;
    transition.(3).(3) <- 0.80 ;
    transition.(3).(0) <- 0.20 ;
    transition.(1).(1) <- 1.0 ;
    transition.(2).(2) <- 1.0 ;
    {
      MC.Regime_sim.states =
        [|
          { label = Regime.Calm; mu = 0.0005; sigma = 0.004; n_observed = 1000 };
          {
            label = Regime.Trending { direction = 1; strength = 0.0 };
            mu = 0.0;
            sigma = 0.01;
            n_observed = 0;
          };
          { label = Regime.Volatile; mu = 0.0; sigma = 0.02; n_observed = 0 };
          { label = Regime.Crisis; mu = -0.004; sigma = 0.03; n_observed = 200 };
        |];
      transition;
      initial = [| 1.0; 0.0; 0.0; 0.0 |];
    }


let test_expected_dwell () =
  let d = MC.Regime_sim.expected_dwell two_state_spec in
    (* 1 / (1 - 0.95) = 20 and 1 / (1 - 0.80) = 5 *)
    Alcotest.(check (float 1e-9)) "calm dwell = 20" 20.0 d.(0) ;
    Alcotest.(check (float 1e-9)) "crisis dwell = 5" 5.0 d.(3)


let test_stationary_distribution () =
  let s = MC.Regime_sim.stationary_distribution two_state_spec in
    (* For a 2-state chain with p01 = 0.05 and p30 = 0.20, stationary calm share is 0.20 / (0.05 +
       0.20) = 0.8. *)
    Alcotest.(check (float 1e-4)) "stationary calm share = 0.8" 0.8 s.(0) ;
    Alcotest.(check (float 1e-4)) "stationary crisis share = 0.2" 0.2 s.(3) ;
    let total = Array.fold_left ( +. ) 0.0 s in
      Alcotest.(check (float 1e-9)) "distribution sums to 1" 1.0 total


let test_simulate_matches_stationary_occupancy () =
  let rng = Rng.create ~seed:7 in
  let labels, rets = MC.Regime_sim.simulate ~rng two_state_spec ~n:200_000 in
    Alcotest.(check int)
      "returns and labels are the same length" (Array.length labels) (Array.length rets) ;
    let calm = Array.fold_left (fun a l -> match l with Regime.Calm -> a + 1 | _ -> a) 0 labels in
    let share = float_of_int calm /. float_of_int (Array.length labels) in
      Alcotest.(check bool)
        (Printf.sprintf "observed calm share %.4f is near the stationary 0.80" share)
        true
        (Float.abs (share -. 0.8) < 0.02)


let test_refit_recovers_transition () =
  let rng = Rng.create ~seed:11 in
  let labels, rets = MC.Regime_sim.simulate ~rng two_state_spec ~n:200_000 in
  let refit = MC.Regime_sim.fit_from_labels ~labels ~returns:rets () in
    Alcotest.(check bool)
      (Printf.sprintf "P(calm->calm) refit as %.4f, true 0.95"
         refit.MC.Regime_sim.transition.(0).(0))
      true
      (Float.abs (refit.MC.Regime_sim.transition.(0).(0) -. 0.95) < 0.02) ;
    Alcotest.(check bool)
      (Printf.sprintf "P(crisis->crisis) refit as %.4f, true 0.80"
         refit.MC.Regime_sim.transition.(3).(3))
      true
      (Float.abs (refit.MC.Regime_sim.transition.(3).(3) -. 0.80) < 0.03)


let test_refit_recovers_emissions () =
  let rng = Rng.create ~seed:13 in
  let labels, rets = MC.Regime_sim.simulate ~rng two_state_spec ~n:200_000 in
  let refit = MC.Regime_sim.fit_from_labels ~labels ~returns:rets () in
  let calm = refit.MC.Regime_sim.states.(0) in
  let crisis = refit.MC.Regime_sim.states.(3) in
    Alcotest.(check bool)
      (Printf.sprintf "calm sigma %.5f near 0.004" calm.MC.Regime_sim.sigma)
      true
      (Float.abs (calm.MC.Regime_sim.sigma -. 0.004) < 0.0005) ;
    Alcotest.(check bool)
      (Printf.sprintf "crisis sigma %.5f near 0.03" crisis.MC.Regime_sim.sigma)
      true
      (Float.abs (crisis.MC.Regime_sim.sigma -. 0.03) < 0.003) ;
    Alcotest.(check bool)
      (Printf.sprintf "crisis mean %.5f is negative" crisis.MC.Regime_sim.mu)
      true (crisis.MC.Regime_sim.mu < 0.0)


let test_forced_break_enters_the_state () =
  let rng = Rng.create ~seed:17 in
  let labels, _ =
    MC.Regime_sim.simulate_with_break ~rng two_state_spec ~n:1000 ~to_state:3 ~at_step:500 in
    Alcotest.(check bool)
      "the break step is in the forced state" true
      (match labels.(500) with Regime.Crisis -> true | _ -> false)


let test_smoothing_prevents_degenerate_rows () =
  (* A single observation of one state must not produce a row of exact zeros and ones. *)
  let labels = [| Regime.Calm; Regime.Calm; Regime.Crisis |] in
  let returns = [| 0.001; 0.002; -0.05 |] in
  let spec = MC.Regime_sim.fit_from_labels ~labels ~returns ~smoothing:1.0 () in
    Array.iteri
      (fun i row ->
        let total = Array.fold_left ( +. ) 0.0 row in
          Alcotest.(check (float 1e-9)) (Printf.sprintf "row %d sums to 1" i) 1.0 total ;
          Array.iteri
            (fun j p ->
              Alcotest.(check bool)
                (Printf.sprintf "P(%d->%d) = %g is a probability" i j p)
                true
                (p >= 0.0 && p <= 1.0))
            row)
      spec.MC.Regime_sim.transition


let suite =
  [
    Alcotest.test_case "expected_dwell" `Quick test_expected_dwell;
    Alcotest.test_case "stationary_distribution" `Quick test_stationary_distribution;
    Alcotest.test_case "simulate_matches_stationary_occupancy" `Quick
      test_simulate_matches_stationary_occupancy;
    Alcotest.test_case "refit_recovers_transition" `Quick test_refit_recovers_transition;
    Alcotest.test_case "refit_recovers_emissions" `Quick test_refit_recovers_emissions;
    Alcotest.test_case "forced_break_enters_the_state" `Quick test_forced_break_enters_the_state;
    Alcotest.test_case "smoothing_prevents_degenerate_rows" `Quick
      test_smoothing_prevents_degenerate_rows;
  ]
