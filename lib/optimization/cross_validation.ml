module Metrics = Algostream_performance.Metrics
module Quantile = Algostream_stochastic.Quantile
module Pool = Algostream_montecarlo.Pool

type scheme =
  | Purged_kfold of {
      k : int;
      embargo_ns : int64;
    }
  | Combinatorial_purged of {
      n_groups : int;
      n_test_groups : int;
      embargo_ns : int64;
    }

type split = {
  index : int;
  train : (int64 * int64) array;
  test : (int64 * int64) array;
}

let rec choose n k =
  if k <= 0 || k >= n then 1 else if k = 1 then n else choose (n - 1) (k - 1) * n / k


let n_splits = function
  | Purged_kfold { k; _ } -> max 1 k
  | Combinatorial_purged { n_groups; n_test_groups; _ } ->
    if n_test_groups <= 0 || n_test_groups >= n_groups then 1 else choose n_groups n_test_groups


(* Split [lo, hi] into g contiguous groups. *)
let group_bounds ~lo_ns ~hi_ns ~g =
  let span = Int64.sub hi_ns lo_ns in
  let step = Int64.div span (Int64.of_int (max 1 g)) in
    Array.init g (fun i ->
      let a = Int64.add lo_ns (Int64.mul (Int64.of_int i) step) in
      let b = if i = g - 1 then hi_ns else Int64.add lo_ns (Int64.mul (Int64.of_int (i + 1)) step) in
        (a, b))


(* Remove from [train] everything inside a test interval, and everything within embargo_ns after
   one. Purging is the intersection removal; the embargo is the forward extension. *)
let purge_train ~groups ~test_idx ~embargo_ns =
  let n = Array.length groups in
  let is_test i = List.mem i test_idx in
  let embargoed i =
    (* group i is embargoed if it starts within embargo_ns of the end of some test group *)
    let a, _ = groups.(i) in
      List.exists
        (fun t ->
          let _, tb = groups.(t) in
            Int64.compare a tb >= 0 && Int64.compare (Int64.sub a tb) embargo_ns < 0)
        test_idx in
  let keep = ref [] in
    for i = n - 1 downto 0 do
      if (not (is_test i)) && not (embargoed i) then keep := groups.(i) :: !keep
    done ;
    Array.of_list !keep


let splits scheme ~lo_ns ~hi_ns =
  match scheme with
  | Purged_kfold { k; embargo_ns } ->
    let k = max 2 k in
    let groups = group_bounds ~lo_ns ~hi_ns ~g:k in
      Array.init k (fun i ->
        {
          index = i;
          train = purge_train ~groups ~test_idx:[ i ] ~embargo_ns;
          test = [| groups.(i) |];
        })
  | Combinatorial_purged { n_groups; n_test_groups; embargo_ns } ->
    let g = max 2 n_groups in
    let m = max 1 (min (g - 1) n_test_groups) in
    let groups = group_bounds ~lo_ns ~hi_ns ~g in
    (* Every m-subset of the g groups becomes one test set. *)
    let combos = ref [] in
    let rec build start acc k =
      if k = 0 then combos := List.rev acc :: !combos
      else
        for i = start to g - k do
          build (i + 1) (i :: acc) (k - 1)
        done in
      build 0 [] m ;
      let combos = List.rev !combos in
        Array.of_list
          (List.mapi
             (fun idx test_idx ->
               {
                 index = idx;
                 train = purge_train ~groups ~test_idx ~embargo_ns;
                 test = Array.of_list (List.map (fun i -> groups.(i)) test_idx);
               })
             combos)


let is_leak_free s ~embargo_ns =
  let overlaps (a1, b1) (a2, b2) = Int64.compare a1 b2 < 0 && Int64.compare a2 b1 < 0 in
    Array.for_all
      (fun tr ->
        Array.for_all
          (fun te ->
            let ta, tb = te in
            (* The test interval extended forward by the embargo. *)
            let guarded = (ta, Int64.add tb embargo_ns) in
              not (overlaps tr guarded))
          s.test)
      s.train


type report = {
  scheme : string;
  per_split : Metrics.t array;
  mean_oos : float;
  oos_distribution : Quantile.summary;
  n_splits : int;
  n_failed : int;
}

let scheme_to_string = function
  | Purged_kfold { k; embargo_ns } -> Printf.sprintf "purged_kfold(k=%d,embargo=%Ldns)" k embargo_ns
  | Combinatorial_purged { n_groups; n_test_groups; embargo_ns } ->
    Printf.sprintf "cpcv(%d choose %d, embargo=%Ldns)" n_groups n_test_groups embargo_ns


let run ~scheme ~lo_ns ~hi_ns ~objective ~eval ~n_domains =
  let ss = splits scheme ~lo_ns ~hi_ns in
  let n = Array.length ss in
  let rs = Pool.map_result ~n_domains ~n ~f:(fun i -> eval ss.(i)) in
  let ok = ref [] in
  let n_failed = ref 0 in
    Array.iter (function Ok m -> ok := m :: !ok | Error _ -> incr n_failed) rs ;
    let per_split = Array.of_list (List.rev !ok) in
    let scores = Array.map (fun m -> Objective.score objective m) per_split in
    let finite = Array.of_list (List.filter Float.is_finite (Array.to_list scores)) in
    let mean =
      if Array.length finite = 0 then 0.0
      else Array.fold_left ( +. ) 0.0 finite /. float_of_int (Array.length finite) in
      {
        scheme = scheme_to_string scheme;
        per_split;
        mean_oos = mean;
        oos_distribution = Quantile.summarize finite;
        n_splits = n;
        n_failed = !n_failed;
      }


let report_to_string r =
  let d = r.oos_distribution in
    Printf.sprintf
      "cv[%s]: %d splits (%d failed)\n\
      \  mean OOS=%.4f  p05=%.4f  p50=%.4f  p95=%.4f  ci95=[%.4f, %.4f]"
      r.scheme r.n_splits r.n_failed r.mean_oos d.Quantile.p05 d.Quantile.p50 d.Quantile.p95
      d.Quantile.ci95_lo d.Quantile.ci95_hi
