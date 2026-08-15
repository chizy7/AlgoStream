module Opt = Algostream_optimization
module WF = Algostream_optimization.Walk_forward
module Metrics = Algostream_performance.Metrics

let day = 86_400_000_000_000L

let lo = 0L

let hi = Int64.mul day 365L

let test_rolling_folds_are_contiguous_and_ordered () =
  let scheme =
    WF.Rolling
      { train_ns = Int64.mul day 90L; test_ns = Int64.mul day 30L; step_ns = Int64.mul day 30L }
  in
  let fs = WF.folds scheme ~lo_ns:lo ~hi_ns:hi in
    Alcotest.(check bool) "some folds were produced" true (Array.length fs > 0) ;
    Array.iteri
      (fun i f ->
        Alcotest.(check int) "index" i f.WF.index ;
        Alcotest.(check bool)
          "test starts where training ends" true
          (Int64.equal f.WF.test_lo_ns f.WF.train_hi_ns) ;
        Alcotest.(check bool)
          "training precedes testing" true
          (Int64.compare f.WF.train_lo_ns f.WF.train_hi_ns < 0) ;
        Alcotest.(check bool)
          "fold stays inside the range" true
          (Int64.compare f.WF.test_hi_ns hi <= 0))
      fs ;
    (* Consecutive test windows must step forward, never overlap backwards. *)
    for i = 1 to Array.length fs - 1 do
      Alcotest.(check bool)
        (Printf.sprintf "fold %d starts after fold %d" i (i - 1))
        true
        (Int64.compare fs.(i).WF.test_lo_ns fs.(i - 1).WF.test_lo_ns > 0)
    done


(* Rolling windows are fixed length; anchored ones grow. That is the whole distinction. *)
let test_rolling_window_is_fixed_anchored_grows () =
  let roll =
    WF.folds
      (WF.Rolling
         { train_ns = Int64.mul day 90L; test_ns = Int64.mul day 30L; step_ns = Int64.mul day 30L })
      ~lo_ns:lo ~hi_ns:hi in
  let anch =
    WF.folds
      (WF.Anchored
         {
           initial_train_ns = Int64.mul day 90L;
           test_ns = Int64.mul day 30L;
           step_ns = Int64.mul day 30L;
         })
      ~lo_ns:lo ~hi_ns:hi in
  let width f = Int64.sub f.WF.train_hi_ns f.WF.train_lo_ns in
    Array.iter
      (fun f ->
        Alcotest.(check int64) "rolling training width is constant" (Int64.mul day 90L) (width f))
      roll ;
    Alcotest.(check bool)
      "anchored training grows" true
      (Array.length anch < 2
      || Int64.compare (width anch.(Array.length anch - 1)) (width anch.(0)) > 0) ;
    Array.iter
      (fun f -> Alcotest.(check int64) "anchored training always starts at lo" lo f.WF.train_lo_ns)
      anch


(* The stitched curve must chain across folds rather than resetting to initial capital at each
   boundary — otherwise every drawdown spanning a boundary silently disappears. *)
let test_stitched_curve_is_continuous () =
  let scheme =
    WF.Rolling
      { train_ns = Int64.mul day 90L; test_ns = Int64.mul day 30L; step_ns = Int64.mul day 30L }
  in
  (* Each fold loses 10%: three folds compounded must end at 0.9^n, not back at 1.0. *)
  let eval f _params =
    let n = 30 in
    let nav =
      Array.init n (fun i ->
        let t = Int64.add f.WF.test_lo_ns (Int64.mul (Int64.of_int i) day) in
        let frac = float_of_int i /. float_of_int (n - 1) in
          (t, 100.0 *. (1.0 -. (0.10 *. frac)))) in
      (Metrics.of_nav ~nav (), nav) in
  let optimize _f =
    {
      Opt.Search.objective = "sharpe";
      trials = [||];
      best =
        Some
          {
            Opt.Search.index = 0;
            params = [ ("x", 1.0) ];
            metrics = None;
            score = 0.0;
            error = None;
          };
      n_evaluated = 1;
      n_failed = 0;
      score_stdev = 0.1;
    } in
  let r = WF.run ~scheme ~lo_ns:lo ~hi_ns:hi ~objective:Opt.Objective.sharpe ~optimize ~eval in
  let nav = r.WF.stitched_oos_nav in
  let n = Array.length nav in
    Alcotest.(check bool) "stitched curve is non-empty" true (n > 0) ;
    let _, first = nav.(0) in
    let _, last = nav.(n - 1) in
    let expected = 100.0 *. (0.9 ** float_of_int r.WF.n_folds) in
      Alcotest.(check bool)
        (Printf.sprintf "compounded to %.3f, expected ~%.3f over %d folds" last expected
           r.WF.n_folds)
        true
        (Float.abs (last -. expected) < 1.0) ;
      Alcotest.(check (float 1e-9)) "starts at the first fold's level" 100.0 first ;
      (* Timestamps must be non-decreasing. *)
      for i = 1 to n - 1 do
        if Int64.compare (fst nav.(i)) (fst nav.(i - 1)) < 0 then
          Alcotest.failf "stitched curve goes backwards in time at %d" i
      done


let test_param_stability_is_zero_for_constant_params () =
  let scheme =
    WF.Rolling
      { train_ns = Int64.mul day 90L; test_ns = Int64.mul day 30L; step_ns = Int64.mul day 30L }
  in
  let eval f _ =
    let nav = [| (f.WF.test_lo_ns, 100.0); (f.WF.test_hi_ns, 101.0) |] in
      (Metrics.of_nav ~nav (), nav) in
  let optimize _f =
    {
      Opt.Search.objective = "sharpe";
      trials = [||];
      best =
        Some
          {
            Opt.Search.index = 0;
            params = [ ("z", 2.0) ];
            metrics = None;
            score = 1.0;
            error = None;
          };
      n_evaluated = 10;
      n_failed = 0;
      score_stdev = 0.2;
    } in
  let r = WF.run ~scheme ~lo_ns:lo ~hi_ns:hi ~objective:Opt.Objective.sharpe ~optimize ~eval in
    Array.iter
      (fun (name, cv) ->
        Alcotest.(check (float 1e-9))
          (Printf.sprintf "%s is perfectly stable across folds" name)
          0.0 cv)
      r.WF.param_stability


let suite =
  [
    Alcotest.test_case "rolling_folds_are_contiguous_and_ordered" `Quick
      test_rolling_folds_are_contiguous_and_ordered;
    Alcotest.test_case "rolling_window_is_fixed_anchored_grows" `Quick
      test_rolling_window_is_fixed_anchored_grows;
    Alcotest.test_case "stitched_curve_is_continuous" `Quick test_stitched_curve_is_continuous;
    Alcotest.test_case "param_stability_is_zero_for_constant_params" `Quick
      test_param_stability_is_zero_for_constant_params;
  ]
