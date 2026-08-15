module Opt = Algostream_optimization
module SS = Algostream_optimization.Search_space
module Metrics = Algostream_performance.Metrics
module Rng = Algostream_rng.Rng

(* Search algorithms are tested against a closed-form objective with a known optimum, not against a
   backtest — that keeps these tests fast and makes a failure unambiguously the searcher's fault. *)

(* Peak at x = 3, y = -1. Encoded through Metrics.sharpe so the objective plumbing is exercised. *)
let quadratic params =
  let get k = match List.assoc_opt k params with Some v -> v | None -> 0.0 in
  let x = get "x" and y = get "y" in
  let score = -.(((x -. 3.0) ** 2.0) +. ((y +. 1.0) ** 2.0)) in
    { Metrics.empty with sharpe = score; n_periods = 100 }


let space =
  [
    { SS.name = "x"; spec = SS.Grid (Array.init 11 (fun i -> float_of_int i)) };
    { SS.name = "y"; spec = SS.Grid (Array.init 11 (fun i -> float_of_int i -. 5.0)) };
  ]


let test_grid_finds_the_optimum () =
  match
    Opt.Search.grid ~space ~objective:Opt.Objective.sharpe ~eval:quadratic ~n_domains:2
      ~max_points:1000
  with
  | Error (`Too_large n) -> Alcotest.failf "unexpectedly too large: %d" n
  | Ok r ->
    Alcotest.(check int) "11 x 11 points evaluated" 121 r.Opt.Search.n_evaluated ;
    Alcotest.(check int) "none failed" 0 r.Opt.Search.n_failed ;
    (match r.Opt.Search.best with
    | None -> Alcotest.fail "no best trial"
    | Some t ->
      Alcotest.(check (float 1e-9)) "x = 3" 3.0 (List.assoc "x" t.Opt.Search.params) ;
      Alcotest.(check (float 1e-9)) "y = -1" (-1.0) (List.assoc "y" t.Opt.Search.params) ;
      Alcotest.(check (float 1e-9)) "score = 0 at the optimum" 0.0 t.Opt.Search.score)


(* A grid too large to enumerate must be refused, not silently sampled — otherwise a partial sweep
   gets reported as if it were exhaustive. *)
let test_grid_refuses_when_too_large () =
  let big =
    List.init 6 (fun i ->
      { SS.name = Printf.sprintf "p%d" i; spec = SS.Grid (Array.init 20 float_of_int) }) in
    match
      Opt.Search.grid ~space:big ~objective:Opt.Objective.sharpe ~eval:quadratic ~n_domains:1
        ~max_points:1000
    with
    | Error (`Too_large n) ->
      Alcotest.(check bool) (Printf.sprintf "reported the true size %d" n) true (n > 1000)
    | Ok _ -> Alcotest.fail "should have refused a 64,000,000-point grid"


let test_results_are_in_trial_order () =
  match
    Opt.Search.grid ~space ~objective:Opt.Objective.sharpe ~eval:quadratic ~n_domains:8
      ~max_points:1000
  with
  | Error _ -> Alcotest.fail "grid failed"
  | Ok r ->
    Array.iteri
      (fun i t ->
        Alcotest.(check int) (Printf.sprintf "trial %d holds index %d" i i) i t.Opt.Search.index)
      r.Opt.Search.trials


let test_random_search_is_seed_reproducible () =
  let go () =
    Opt.Search.random ~space ~objective:Opt.Objective.sharpe ~eval:quadratic ~n_domains:4 ~n:200
      ~root_seed:1234L in
  let a = go () and b = go () in
    Alcotest.(check int) "same trial count" a.Opt.Search.n_evaluated b.Opt.Search.n_evaluated ;
    Array.iteri
      (fun i t ->
        Alcotest.(check (float 1e-12))
          (Printf.sprintf "trial %d score" i)
          t.Opt.Search.score b.Opt.Search.trials.(i).Opt.Search.score)
      a.Opt.Search.trials


(* What stratified sampling actually guarantees is even MARGINAL coverage — every axis is cut into n
   strata and each gets exactly one sample. It does not promise to find a specific joint optimum
   faster; on a discrete grid with a single 2-D peak, random search does about as well, and an
   earlier version of this test asserted the stronger claim and rightly failed.

   So the property tested here is the one that holds: the largest gap between consecutive sampled
   values along an axis is smaller under stratified sampling than under independent draws. That is
   the coverage advantage, measured directly. *)
let test_stratified_has_smaller_marginal_gaps () =
  let continuous =
    [
      { SS.name = "x"; spec = SS.Uniform { lo = 0.0; hi = 1.0 } };
      { SS.name = "y"; spec = SS.Uniform { lo = 0.0; hi = 1.0 } };
    ] in
  let n = 64 in
  let max_gap points axis =
    let vs = Array.of_list (List.map (fun p -> List.assoc axis p) (Array.to_list points)) in
      Array.sort compare vs ;
      let worst = ref vs.(0) in
        for i = 1 to Array.length vs - 1 do
          let g = vs.(i) -. vs.(i - 1) in
            if g > !worst then worst := g
        done ;
        Float.max !worst (1.0 -. vs.(Array.length vs - 1)) in
  let avg l = List.fold_left ( +. ) 0.0 l /. float_of_int (List.length l) in
  let seeds = [ 1; 2; 3; 4; 5; 6; 7; 8 ] in
  let strat_gaps =
    List.map
      (fun seed ->
        let pts = SS.stratified_points continuous (Rng.create ~seed) ~n in
          max_gap pts "x")
      seeds in
  let random_gaps =
    List.map
      (fun seed ->
        let pts = SS.random_points continuous (Rng.create ~seed) ~n in
          max_gap pts "x")
      seeds in
  let gs = avg strat_gaps and gr = avg random_gaps in
    Alcotest.(check bool)
      (Printf.sprintf "stratified largest marginal gap %.5f < random's %.5f" gs gr)
      true (gs < gr)


let test_coordinate_descent_climbs () =
  let r =
    Opt.Search.coordinate_descent ~space ~objective:Opt.Objective.sharpe ~eval:quadratic
      ~x0:[ ("x", 0.0); ("y", -5.0) ]
      ~max_passes:20 in
    match r.Opt.Search.best with
    | None -> Alcotest.fail "no best"
    | Some t ->
      Alcotest.(check (float 1e-9)) "reaches x = 3" 3.0 (List.assoc "x" t.Opt.Search.params) ;
      Alcotest.(check (float 1e-9)) "reaches y = -1" (-1.0) (List.assoc "y" t.Opt.Search.params)


(* Nelder-Mead's own documented bound is 4 dimensions. Above it we refuse rather than run badly and
   report the poor optimum as though it were good. *)
let test_nelder_mead_refuses_above_four_dims () =
  let x0 = List.init 6 (fun i -> (Printf.sprintf "p%d" i, 0.0)) in
    match
      Opt.Search.nelder_mead_refine ~space ~objective:Opt.Objective.sharpe ~eval:quadratic ~x0
    with
    | Error (`Too_many_dimensions n) -> Alcotest.(check int) "reports the dimension count" 6 n
    | Ok _ -> Alcotest.fail "should have refused 6 dimensions"


let test_failed_evaluations_do_not_win () =
  let eval params = if List.assoc "x" params > 5.0 then failwith "blow up" else quadratic params in
    match
      Opt.Search.grid ~space ~objective:Opt.Objective.sharpe ~eval ~n_domains:4 ~max_points:1000
    with
    | Error _ -> Alcotest.fail "grid failed"
    | Ok r ->
      Alcotest.(check bool) "some trials failed" true (r.Opt.Search.n_failed > 0) ;
      (match r.Opt.Search.best with
      | None -> Alcotest.fail "no best despite successful trials"
      | Some t ->
        Alcotest.(check bool) "the winner is not a failed trial" true (t.Opt.Search.error = None) ;
        Alcotest.(check bool) "and has a finite score" true (Float.is_finite t.Opt.Search.score))


let suite =
  [
    Alcotest.test_case "grid_finds_the_optimum" `Quick test_grid_finds_the_optimum;
    Alcotest.test_case "grid_refuses_when_too_large" `Quick test_grid_refuses_when_too_large;
    Alcotest.test_case "results_are_in_trial_order" `Quick test_results_are_in_trial_order;
    Alcotest.test_case "random_search_is_seed_reproducible" `Quick
      test_random_search_is_seed_reproducible;
    Alcotest.test_case "stratified_has_smaller_marginal_gaps" `Quick
      test_stratified_has_smaller_marginal_gaps;
    Alcotest.test_case "coordinate_descent_climbs" `Quick test_coordinate_descent_climbs;
    Alcotest.test_case "nelder_mead_refuses_above_four_dims" `Quick
      test_nelder_mead_refuses_above_four_dims;
    Alcotest.test_case "failed_evaluations_do_not_win" `Quick test_failed_evaluations_do_not_win;
  ]
