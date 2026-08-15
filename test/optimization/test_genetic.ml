(* The genetic algorithm.

   Replaces test_genetic_stub.ml, which pinned the deliberate non-implementation — the same guard
   test/pairs still applies to Cointegration.Johansen. That tripwire was there so the stub could not
   rot into something that silently returned a plausible-looking result; it has been removed
   knowingly, because the result is no longer a stub.

   The cases here are chosen around what is actually easy to get wrong in a GA:

   - reproducibility, which is the property the whole optimization layer is built on; - that
   n_evaluated is the *true* budget, since that is what Overfitting.deflated_sharpe_ratio charges
   the search for and the tempting bug is to report only the surviving population; - that the search
   stays inside its declared space, which crossover and mutation both violate before clamping; -
   that a failing evaluation cannot take the run down.

   Optimum-finding itself is checked on a closed-form surface, so "did it work" has an answer that
   does not depend on market data. *)

module Opt = Algostream_optimization
module SS = Algostream_optimization.Search_space
module Metrics = Algostream_performance.Metrics

(* A quadratic bowl in two dimensions with its peak at (3, -2), reported through the one Metrics
   field Objective.sharpe reads. The optimum is interior, so clamping cannot reach it by accident —
   a search that merely ran to a boundary would score badly. *)
let peak_x = 3.0

let peak_y = -2.0

let space =
  [
    { SS.name = "x"; spec = SS.Uniform { lo = -10.0; hi = 10.0 } };
    { SS.name = "y"; spec = SS.Uniform { lo = -10.0; hi = 10.0 } };
  ]


let get p k = match List.assoc_opt k p with Some v -> v | None -> nan

let bowl p =
  let dx = get p "x" -. peak_x and dy = get p "y" -. peak_y in
    { Metrics.empty with Metrics.sharpe = -.((dx *. dx) +. (dy *. dy)) }


let small = { Opt.Genetic.default_config with Opt.Genetic.population = 24; generations = 12 }

let run ?(config = small) ?(eval = bowl) ?(seed = 7L) () =
  match
    Opt.Genetic.optimize ~space ~objective:Opt.Objective.sharpe ~eval ~config ~root_seed:seed
      ~n_domains:1
  with
  | Ok r -> r
  | Error e -> Alcotest.failf "optimize failed: %s" (Opt.Genetic.error_to_string e)


let test_finds_the_known_optimum () =
  let r = run () in
    match r.Opt.Search.best with
    | None -> Alcotest.fail "no best trial"
    | Some b ->
      let dx = get b.Opt.Search.params "x" -. peak_x in
      let dy = get b.Opt.Search.params "y" -. peak_y in
      let dist = sqrt ((dx *. dx) +. (dy *. dy)) in
        (* Loose on purpose: this asserts the search converges on the right region of a 20x20 box,
           not that it terminates at machine precision. A GA is not a local refiner. *)
        Alcotest.(check bool)
          (Printf.sprintf "best is near (%g, %g); got (%g, %g), distance %.3f" peak_x peak_y
             (get b.Opt.Search.params "x") (get b.Opt.Search.params "y") dist)
          true (dist < 0.5)


let test_is_reproducible_from_the_seed () =
  (* The property the whole layer depends on. Compared over every trial, not just the best, so a
     difference anywhere in the population is caught. *)
  let a = run () and b = run () in
    Alcotest.(check int)
      "same number of trials"
      (Array.length a.Opt.Search.trials)
      (Array.length b.Opt.Search.trials) ;
    Array.iteri
      (fun i (t : Opt.Search.trial) ->
        let u = b.Opt.Search.trials.(i) in
          Alcotest.(check (float 0.0))
            (Printf.sprintf "trial %d score" i)
            t.Opt.Search.score u.Opt.Search.score ;
          Alcotest.(check (float 0.0))
            (Printf.sprintf "trial %d x" i) (get t.Opt.Search.params "x")
            (get u.Opt.Search.params "x"))
      a.Opt.Search.trials


let test_a_different_seed_explores_differently () =
  (* The companion: if the seed were ignored, the test above would pass vacuously. *)
  let a = run ~seed:7L () and b = run ~seed:99L () in
  let first r = get r.Opt.Search.trials.(0).Opt.Search.params "x" in
    Alcotest.(check bool)
      "a different root_seed gives a different initial population" true
      (Float.abs (first a -. first b) > 1e-12)


let test_n_evaluated_is_the_whole_budget () =
  (* n_trials in the deflated Sharpe correction. Reporting only the final population — 24 rather
     than 312 here — would understate the search's selection bias by an order of magnitude. *)
  let r = run () in
  let expected = small.Opt.Genetic.population * (small.Opt.Genetic.generations + 1) in
    Alcotest.(check int) "every generation is counted" expected r.Opt.Search.n_evaluated ;
    Alcotest.(check int) "and every trial is retained" expected (Array.length r.Opt.Search.trials)


let test_trial_indices_are_a_dense_sequence () =
  (* Search.evaluate numbers within a batch; the GA runs many batches and must renumber. Duplicate
     indices would make trials indistinguishable to anything joining on them. *)
  let r = run () in
    Array.iteri
      (fun i (t : Opt.Search.trial) ->
        Alcotest.(check int) (Printf.sprintf "trial at position %d" i) i t.Opt.Search.index)
      r.Opt.Search.trials


let test_every_point_stays_inside_the_space () =
  (* BLX-α widens beyond the parents' interval and Gaussian mutation is unbounded, so without the
     clamp the search leaves the declared box within a generation or two — and would report an
     optimum at parameters the strategy never agreed to accept. *)
  let r = run () in
    Array.iter
      (fun (t : Opt.Search.trial) ->
        List.iter
          (fun (k, v) ->
            Alcotest.(check bool)
              (Printf.sprintf "%s=%g within [-10, 10]" k v)
              true
              (v >= -10.0 && v <= 10.0))
          t.Opt.Search.params)
      r.Opt.Search.trials


let test_elitism_means_the_best_never_regresses () =
  let r = run () in
  let pop = small.Opt.Genetic.population in
  let best_of gen =
    let lo = gen * pop in
    let acc = ref neg_infinity in
      for i = lo to min (lo + pop - 1) (Array.length r.Opt.Search.trials - 1) do
        let s = r.Opt.Search.trials.(i).Opt.Search.score in
          if s > !acc then acc := s
      done ;
      !acc in
  let prev = ref (best_of 0) in
    for g = 1 to small.Opt.Genetic.generations do
      let b = best_of g in
        Alcotest.(check bool)
          (Printf.sprintf "generation %d best (%.4f) >= previous (%.4f)" g b !prev)
          true
          (b >= !prev -. 1e-12) ;
        prev := b
    done


let test_a_raising_evaluation_becomes_a_failed_trial () =
  (* One bad point must not abort a run that may have cost minutes. *)
  let boom p = if get p "x" > 0.0 then failwith "synthetic evaluation failure" else bowl p in
  let r = run ~eval:boom () in
    Alcotest.(check bool) "some trials failed" true (r.Opt.Search.n_failed > 0) ;
    Alcotest.(check bool)
      "but the run completed and still found a best" true (r.Opt.Search.best <> None) ;
    match r.Opt.Search.best with
    | Some b ->
      Alcotest.(check bool) "the best is not a failed trial" true (b.Opt.Search.error = None)
    | None -> ()


let test_config_is_validated () =
  let bad c =
    match
      Opt.Genetic.optimize ~space ~objective:Opt.Objective.sharpe ~eval:bowl ~config:c ~root_seed:1L
        ~n_domains:1
    with
    | Error (`Bad_config _) -> ()
    | Error e -> Alcotest.failf "wrong error: %s" (Opt.Genetic.error_to_string e)
    | Ok _ -> Alcotest.fail "an invalid config was accepted" in
    bad { small with Opt.Genetic.population = 1 } ;
    bad { small with Opt.Genetic.elitism = small.Opt.Genetic.population } ;
    bad { small with Opt.Genetic.tournament_size = 0 } ;
    bad { small with Opt.Genetic.mutation_rate = 1.5 }


let test_empty_space_is_refused () =
  match
    Opt.Genetic.optimize ~space:[] ~objective:Opt.Objective.sharpe ~eval:bowl ~config:small
      ~root_seed:1L ~n_domains:1
  with
  | Error `Empty_space -> ()
  | Error e -> Alcotest.failf "wrong error: %s" (Opt.Genetic.error_to_string e)
  | Ok _ -> Alcotest.fail "optimizing an empty space returned a result"


(* The comparison the module documentation demands: a GA against stratified search at *equal
   evaluation budget*, scored after the deflated-Sharpe correction rather than on the raw figure.

   This asserts that the accounting is applied and self-consistent, not that the GA wins — which
   surface wins is a property of the surface, and asserting a winner would make this a test of the
   bowl rather than of the code. What must hold is that both searches are charged for the budget
   they actually spent. *)
let test_equal_budget_comparison_is_deflation_aware () =
  let budget = small.Opt.Genetic.population * (small.Opt.Genetic.generations + 1) in
  let ga = run () in
  let lhs =
    Opt.Search.stratified ~space ~objective:Opt.Objective.sharpe ~eval:bowl ~n_domains:1 ~n:budget
      ~root_seed:7L in
    Alcotest.(check int) "the GA spent the stated budget" budget ga.Opt.Search.n_evaluated ;
    Alcotest.(check int) "and so did stratified search" budget lhs.Opt.Search.n_evaluated ;
    (* Same n_trials on both sides, so the correction cannot favour either by construction. *)
    let deflate (r : Opt.Search.report) =
      let observed = match r.Opt.Search.best with Some b -> b.Opt.Search.score | None -> 0.0 in
        Opt.Overfitting.deflated_sharpe_ratio ~observed_sharpe:observed
          ~n_trials:r.Opt.Search.n_evaluated ~trial_sharpe_stdev:r.Opt.Search.score_stdev
          ~skewness:0.0 ~excess_kurtosis:0.0 ~n_obs:512 in
    let dsr_ga = deflate ga and dsr_lhs = deflate lhs in
      List.iter
        (fun (name, v) ->
          Alcotest.(check bool)
            (Printf.sprintf "%s deflated Sharpe is a probability (%.6f)" name v)
            true
            (v >= 0.0 && v <= 1.0))
        [ ("ga", dsr_ga); ("stratified", dsr_lhs) ] ;
      (* Both searches are charged for 312 trials; neither gets to quote a raw best. *)
      Alcotest.(check bool)
        "both were charged the same n_trials" true
        (ga.Opt.Search.n_evaluated = lhs.Opt.Search.n_evaluated)


let suite =
  [
    Alcotest.test_case "finds_the_known_optimum" `Quick test_finds_the_known_optimum;
    Alcotest.test_case "is_reproducible_from_the_seed" `Quick test_is_reproducible_from_the_seed;
    Alcotest.test_case "a_different_seed_explores_differently" `Quick
      test_a_different_seed_explores_differently;
    Alcotest.test_case "n_evaluated_is_the_whole_budget" `Quick test_n_evaluated_is_the_whole_budget;
    Alcotest.test_case "trial_indices_are_a_dense_sequence" `Quick
      test_trial_indices_are_a_dense_sequence;
    Alcotest.test_case "every_point_stays_inside_the_space" `Quick
      test_every_point_stays_inside_the_space;
    Alcotest.test_case "elitism_means_the_best_never_regresses" `Quick
      test_elitism_means_the_best_never_regresses;
    Alcotest.test_case "a_raising_evaluation_becomes_a_failed_trial" `Quick
      test_a_raising_evaluation_becomes_a_failed_trial;
    Alcotest.test_case "config_is_validated" `Quick test_config_is_validated;
    Alcotest.test_case "empty_space_is_refused" `Quick test_empty_space_is_refused;
    Alcotest.test_case "equal_budget_comparison_is_deflation_aware" `Quick
      test_equal_budget_comparison_is_deflation_aware;
  ]
