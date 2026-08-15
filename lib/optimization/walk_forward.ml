module Metrics = Algostream_performance.Metrics

type scheme =
  | Rolling of {
      train_ns : int64;
      test_ns : int64;
      step_ns : int64;
    }
  | Anchored of {
      initial_train_ns : int64;
      test_ns : int64;
      step_ns : int64;
    }

type fold = {
  index : int;
  train_lo_ns : int64;
  train_hi_ns : int64;
  test_lo_ns : int64;
  test_hi_ns : int64;
}

let folds scheme ~lo_ns ~hi_ns =
  let out = ref [] in
  let idx = ref 0 in
    (match scheme with
    | Rolling { train_ns; test_ns; step_ns } ->
      let step = if Int64.compare step_ns 0L <= 0 then test_ns else step_ns in
      let cursor = ref lo_ns in
        while Int64.compare (Int64.add !cursor (Int64.add train_ns test_ns)) hi_ns <= 0 do
          let train_hi = Int64.add !cursor train_ns in
            out :=
              {
                index = !idx;
                train_lo_ns = !cursor;
                train_hi_ns = train_hi;
                test_lo_ns = train_hi;
                test_hi_ns = Int64.add train_hi test_ns;
              }
              :: !out ;
            incr idx ;
            cursor := Int64.add !cursor step
        done
    | Anchored { initial_train_ns; test_ns; step_ns } ->
      let step = if Int64.compare step_ns 0L <= 0 then test_ns else step_ns in
      let train_hi = ref (Int64.add lo_ns initial_train_ns) in
        while Int64.compare (Int64.add !train_hi test_ns) hi_ns <= 0 do
          out :=
            {
              index = !idx;
              (* Anchored: the training window always starts at lo_ns and grows. *)
              train_lo_ns = lo_ns;
              train_hi_ns = !train_hi;
              test_lo_ns = !train_hi;
              test_hi_ns = Int64.add !train_hi test_ns;
            }
            :: !out ;
          incr idx ;
          train_hi := Int64.add !train_hi step
        done) ;
    Array.of_list (List.rev !out)


type window = {
  fold : fold;
  best_params : (string * float) list;
  in_sample : Metrics.t;
  out_of_sample : Metrics.t;
  n_trials : int;
  score_stdev : float;
}

type report = {
  windows : window array;
  stitched_oos : Metrics.t;
  stitched_oos_nav : (int64 * float) array;
  walk_forward_efficiency : float;
  degradation : float;
  param_stability : (string * float) array;
  n_folds : int;
  n_folds_positive : int;
  deflated_sharpe : float;
}

let mean xs =
  let finite = List.filter Float.is_finite xs in
    match finite with
    | [] -> 0.0
    | _ -> List.fold_left ( +. ) 0.0 finite /. float_of_int (List.length finite)


(* Chain per-fold NAV curves so each starts where the previous ended. Rebasing every fold to the
   initial capital would erase any drawdown spanning a boundary. *)
let stitch_nav curves =
  let out = ref [] in
  let carry = ref 1.0 in
  let started = ref false in
    List.iter
      (fun curve ->
        let n = Array.length curve in
          if n > 0 then
            let _, first = curve.(0) in
              if first > 0.0 then (
                let scale = if !started then !carry /. first else 1.0 in
                  Array.iter (fun (ts, v) -> out := (ts, v *. scale) :: !out) curve ;
                  let _, last = curve.(n - 1) in
                    carry := last *. scale ;
                    started := true))
      curves ;
    Array.of_list (List.rev !out)


let param_stability windows =
  match Array.length windows with
  | 0 -> [||]
  | _ ->
    let names = List.map fst windows.(0).best_params in
      Array.of_list
        (List.map
           (fun name ->
             let vs =
               Array.to_list
                 (Array.map
                    (fun w ->
                      match List.assoc_opt name w.best_params with Some v -> v | None -> 0.0)
                    windows) in
             let m = mean vs in
             let n = List.length vs in
             let sd =
               if n < 2 then 0.0
               else
                 sqrt
                   (List.fold_left (fun a v -> a +. ((v -. m) *. (v -. m))) 0.0 vs
                   /. float_of_int (n - 1)) in
               (* Coefficient of variation: scale-free, so window lengths and z-thresholds are
                  comparable on one axis. *)
               (name, if Float.abs m < 1e-12 then 0.0 else sd /. Float.abs m))
           names)


let run ~scheme ~lo_ns ~hi_ns ~objective ~optimize ~eval =
  let fs = folds scheme ~lo_ns ~hi_ns in
  let windows =
    Array.map
      (fun f ->
        let rep = optimize f in
        let best = match rep.Search.best with Some t -> t.Search.params | None -> [] in
        let is_metrics =
          match rep.Search.best with Some { Search.metrics = Some m; _ } -> m | _ -> Metrics.empty
        in
        let oos_metrics, _ = eval f best in
          {
            fold = f;
            best_params = best;
            in_sample = is_metrics;
            out_of_sample = oos_metrics;
            n_trials = rep.Search.n_evaluated;
            score_stdev = rep.Search.score_stdev;
          })
      fs in
  let curves = Array.to_list (Array.map (fun w -> snd (eval w.fold w.best_params)) windows) in
  let stitched_nav = stitch_nav curves in
  let stitched = Metrics.of_nav ~nav:stitched_nav () in
  let is_scores =
    Array.to_list (Array.map (fun w -> Objective.score objective w.in_sample) windows) in
  let oos_scores =
    Array.to_list (Array.map (fun w -> Objective.score objective w.out_of_sample) windows) in
  let mean_is = mean is_scores and mean_oos = mean oos_scores in
  let total_trials = Array.fold_left (fun a w -> a + w.n_trials) 0 windows in
  let trial_sd = mean (Array.to_list (Array.map (fun w -> w.score_stdev) windows)) in
    {
      windows;
      stitched_oos = stitched;
      stitched_oos_nav = stitched_nav;
      walk_forward_efficiency = (if Float.abs mean_is < 1e-12 then 0.0 else mean_oos /. mean_is);
      degradation = mean_is -. mean_oos;
      param_stability = param_stability windows;
      n_folds = Array.length windows;
      n_folds_positive =
        Array.fold_left
          (fun a w -> if w.out_of_sample.Metrics.total_return > 0.0 then a + 1 else a)
          0 windows;
      (* Charged against the TOTAL trials across all folds — the search saw the whole sample, so
         that is the multiple-testing budget that actually applies. *)
      deflated_sharpe =
        Overfitting.deflated_sharpe_ratio ~observed_sharpe:stitched.Metrics.sharpe
          ~n_trials:(max 1 total_trials)
          ~trial_sharpe_stdev:(if trial_sd > 0.0 then trial_sd else 1.0)
          ~skewness:stitched.Metrics.skewness ~excess_kurtosis:stitched.Metrics.excess_kurtosis
          ~n_obs:stitched.Metrics.n_periods;
    }


let report_to_string r =
  let b = Buffer.create 512 in
    Buffer.add_string b
      (Printf.sprintf "walk-forward: %d folds, %d with positive OOS return\n" r.n_folds
         r.n_folds_positive) ;
    Buffer.add_string b
      (Printf.sprintf "  stitched OOS: sharpe=%.3f calmar=%.3f maxDD=%.2f%% return=%.2f%%\n"
         r.stitched_oos.Metrics.sharpe r.stitched_oos.Metrics.calmar
         (r.stitched_oos.Metrics.max_drawdown *. 100.0)
         (r.stitched_oos.Metrics.total_return *. 100.0)) ;
    Buffer.add_string b
      (Printf.sprintf "  efficiency=%.3f degradation=%.3f deflated_sharpe=%.3f\n"
         r.walk_forward_efficiency r.degradation r.deflated_sharpe) ;
    Buffer.add_string b
      (Printf.sprintf "  param stability (cv): %s\n"
         (String.concat " "
            (Array.to_list
               (Array.map (fun (k, v) -> Printf.sprintf "%s=%.2f" k v) r.param_stability)))) ;
    Buffer.contents b
