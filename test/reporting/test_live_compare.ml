(* Live strategy comparison.

   The anchor is the identical-curves case, in the spirit of test/runtime/test_parity.ml: if two
   instances produced the same equity, every comparison figure must be exactly neutral — active
   return 0, correlation 1, beta 1. That single assertion catches misalignment, an inverted
   benchmark argument, and accidentally shared state, none of which a "looks plausible" check would.

   The alignment cases exist because that is the part with no prior art. Benchmark_compare truncates
   two series to the shorter length and assumes a common grid, which is true of a backtest and false
   of two live instances sampling on their own timers. *)

module LC = Algostream_reporting.Live_compare
module NA = Algostream_performance.Nav_align
module BC = Algostream_performance.Benchmark_compare

let sec n = Int64.mul (Int64.of_int n) 1_000_000_000L

(* A curve sampled once a second from t=0. *)
let curve_from ?(start = 0) values =
  Array.of_list (List.mapi (fun i v -> (sec (start + i), v)) values)


let ramp ?(start = 0) ?(n = 40) ?(v0 = 100_000.0) ~step () =
  curve_from ~start (List.init n (fun i -> v0 +. (float_of_int i *. step)))


let ok = function
  | Ok r -> r
  | Error e -> Alcotest.failf "comparison failed: %s" (LC.error_to_string e)


(* ── the anchor ────────────────────────────────────────────────────────── *)

let test_identical_curves_are_exactly_neutral () =
  let c = ramp ~step:10.0 () in
  let r = ok (LC.of_curves ~a_id:"a" ~b_id:"b" ~a:c ~b:(Array.copy c)) in
    Alcotest.(check int) "grid covers every sample" (Array.length c) r.LC.n_periods ;
    Alcotest.(check (float 0.0))
      "active return is exactly zero" 0.0 r.LC.relative.BC.active_return_ann ;
    Alcotest.(check (float 0.0)) "alpha is exactly zero" 0.0 r.LC.relative.BC.alpha_ann ;
    Alcotest.(check (float 0.0))
      "tracking error is exactly zero" 0.0 r.LC.relative.BC.tracking_error_ann ;
    Alcotest.(check (float 1e-12)) "beta is one" 1.0 r.LC.relative.BC.beta ;
    Alcotest.(check (float 1e-12)) "correlation is one" 1.0 r.LC.relative.BC.correlation ;
    (* And both arms must report the same standalone metrics, since they saw the same equity. *)
    Alcotest.(check (float 1e-12))
      "same total return" r.LC.a_metrics.Algostream_performance.Metrics.total_return
      r.LC.b_metrics.Algostream_performance.Metrics.total_return


let test_a_better_arm_shows_positive_active_return () =
  (* Direction, not magnitude: b climbs faster than a over the same window. *)
  let a = ramp ~step:10.0 () and b = ramp ~step:30.0 () in
  let r = ok (LC.of_curves ~a_id:"a" ~b_id:"b" ~a ~b) in
    Alcotest.(check bool)
      (Printf.sprintf "b outperforms a (active return %+.6f)" r.LC.relative.BC.active_return_ann)
      true
      (r.LC.relative.BC.active_return_ann > 0.0) ;
    Alcotest.(check bool)
      "and the sign flips when the arms are swapped" true
      (let s = ok (LC.of_curves ~a_id:"b" ~b_id:"a" ~a:b ~b:a) in
         s.LC.relative.BC.active_return_ann < 0.0)


(* ── alignment ─────────────────────────────────────────────────────────── *)

let test_an_instance_added_late_is_compared_only_on_the_overlap () =
  (* b starts 20 seconds after a. Comparing positionally would pair a's first sample with b's first
     sample — twenty seconds apart — and report a relationship between unrelated points. *)
  let a = ramp ~n:40 ~step:10.0 () in
  let b = ramp ~start:20 ~n:40 ~step:10.0 () in
  let r = ok (LC.of_curves ~a_id:"a" ~b_id:"b" ~a ~b) in
    (* The common window is t=20s..39s inclusive: 20 points. *)
    Alcotest.(check int) "only the overlapping window is used" 20 r.LC.n_periods ;
    Alcotest.(check bool)
      "the grid starts at the later of the two starts" true
      (Int64.equal (fst r.LC.a_curve.(0)) (sec 20)) ;
    Alcotest.(check bool)
      "and ends at the earlier of the two ends" true
      (Int64.equal (fst r.LC.a_curve.(r.LC.n_periods - 1)) (sec 39))


let test_a_paused_instance_carries_its_last_value_forward () =
  (* a samples every second; b stopped sampling at t=10 and resumes at t=30 — a pause. Its NAV over
     the gap is what it last was, not an interpolation towards where it later ended up. *)
  let a = ramp ~n:40 ~step:10.0 () in
  let b =
    Array.append
      (curve_from (List.init 11 (fun i -> 100_000.0 +. (float_of_int i *. 10.0))))
      (curve_from ~start:30 (List.init 10 (fun i -> 200_000.0 +. (float_of_int i *. 10.0)))) in
  let al = NA.align a b in
  (* At t=20, inside b's gap, b must read its t=10 value of 100_100 — not something between 100_100
     and 200_000. *)
  let idx =
    let found = ref (-1) in
      Array.iteri (fun i t -> if Int64.equal t (sec 20) then found := i) al.NA.ts_ns ;
      !found in
    Alcotest.(check bool) "t=20 is on the grid" true (idx >= 0) ;
    Alcotest.(check (float 1e-9))
      "b holds its last observation across the pause" 100_100.0 al.NA.b.(idx)


let test_union_grid_keeps_every_observation () =
  (* Interleaved sampling: a on even seconds, b on odd. An intersection would be empty; the union
     keeps all of them. *)
  let a = Array.of_list (List.init 10 (fun i -> (sec (2 * i), 100_000.0 +. float_of_int i))) in
  let b = Array.of_list (List.init 10 (fun i -> (sec ((2 * i) + 1), 100_000.0 +. float_of_int i))) in
  let al = NA.align a b in
    (* Common window is t=1..18; both series' timestamps inside it: a has 1..9 at even 2..18 (9
       points), b has odd 1..17 (9 points) — 18 in total, all distinct. *)
    Alcotest.(check int) "union of both timestamp sets" 18 al.NA.n ;
    Alcotest.(check bool)
      "strictly ascending with no duplicates" true
      (let ordered = ref true in
         Array.iteri
           (fun i t -> if i > 0 && Int64.compare t al.NA.ts_ns.(i - 1) <= 0 then ordered := false)
           al.NA.ts_ns ;
         !ordered)


let test_unsorted_and_duplicated_input_is_tolerated () =
  (* The ring publishes oldest-first, but nothing in the type says so, and a duplicate timestamp is
     possible when two samples land in the same nanosecond. Last value wins. *)
  let a = [| (sec 3, 103.0); (sec 1, 101.0); (sec 2, 102.0); (sec 2, 999.0) |] in
  let b = [| (sec 1, 201.0); (sec 2, 202.0); (sec 3, 203.0) |] in
  let al = NA.align a b in
    Alcotest.(check int) "three distinct timestamps" 3 al.NA.n ;
    Alcotest.(check (float 1e-9)) "sorted ascending" 101.0 al.NA.a.(0) ;
    Alcotest.(check (float 1e-9)) "duplicate resolved to the last value" 999.0 al.NA.a.(1)


(* ── refusals ──────────────────────────────────────────────────────────── *)

let test_disjoint_windows_are_refused () =
  let a = ramp ~n:20 ~step:10.0 () in
  let b = ramp ~start:100 ~n:20 ~step:10.0 () in
    match LC.of_curves ~a_id:"a" ~b_id:"b" ~a ~b with
    | Error `No_overlap -> ()
    | Error e -> Alcotest.failf "wrong error: %s" (LC.error_to_string e)
    | Ok _ -> Alcotest.fail "curves that never overlap produced a comparison"


let test_too_few_points_is_refused_rather_than_reported () =
  (* Beta and correlation over three points are noise. Declining is the honest answer. *)
  let a = ramp ~n:3 ~step:10.0 () and b = ramp ~n:3 ~step:20.0 () in
    match LC.of_curves ~a_id:"a" ~b_id:"b" ~a ~b with
    | Error (`Too_short n) -> Alcotest.(check bool) "reports how many it had" true (n > 0 && n < 8)
    | Error e -> Alcotest.failf "wrong error: %s" (LC.error_to_string e)
    | Ok _ -> Alcotest.fail "a three-point comparison was reported"


let test_comparing_an_instance_with_itself_is_refused () =
  let c = ramp ~step:10.0 () in
    match LC.of_curves ~a_id:"same" ~b_id:"same" ~a:c ~b:c with
    | Error (`Same_instance _) -> ()
    | Error e -> Alcotest.failf "wrong error: %s" (LC.error_to_string e)
    | Ok _ -> Alcotest.fail "an instance was compared with itself"


let test_empty_curve_is_refused () =
  let c = ramp ~step:10.0 () in
    match LC.of_curves ~a_id:"a" ~b_id:"b" ~a:c ~b:[||] with
    | Error `No_overlap -> ()
    | Error e -> Alcotest.failf "wrong error: %s" (LC.error_to_string e)
    | Ok _ -> Alcotest.fail "an empty curve produced a comparison"


(* ── serialisation ─────────────────────────────────────────────────────── *)

let test_json_has_the_shape_the_dashboard_reads () =
  let a = ramp ~step:10.0 () and b = ramp ~step:20.0 () in
  let r = ok (LC.of_curves ~a_id:"alpha" ~b_id:"beta" ~a ~b) in
  let j = LC.to_json r in
  let member k = function `Assoc kvs -> List.assoc_opt k kvs | _ -> None in
    List.iter
      (fun k ->
        Alcotest.(check bool) (Printf.sprintf "top-level %S present" k) true (member k j <> None))
      [ "a_id"; "b_id"; "n_periods"; "overlap_ns"; "periods_per_year"; "a"; "b"; "b_vs_a" ] ;
    (match member "a" j with
    | Some arm ->
      Alcotest.(check bool) "arm has metrics" true (member "metrics" arm <> None) ;
      (match member "curve" arm with
      | Some (`List pts) ->
        Alcotest.(check int) "curve length matches n_periods" r.LC.n_periods (List.length pts)
      | _ -> Alcotest.fail "arm curve is not a list")
    | None -> Alcotest.fail "no a arm") ;
    (* Round-trips through a real parser: a NaN emitted as a bare token would produce invalid JSON
       that only a browser would discover. *)
    let s = Yojson.Safe.to_string j in
      match Yojson.Safe.from_string s with
      | _ -> Alcotest.(check bool) "serialises to parseable JSON" true true


let suite =
  [
    Alcotest.test_case "identical_curves_are_exactly_neutral" `Quick
      test_identical_curves_are_exactly_neutral;
    Alcotest.test_case "a_better_arm_shows_positive_active_return" `Quick
      test_a_better_arm_shows_positive_active_return;
    Alcotest.test_case "an_instance_added_late_is_compared_only_on_the_overlap" `Quick
      test_an_instance_added_late_is_compared_only_on_the_overlap;
    Alcotest.test_case "a_paused_instance_carries_its_last_value_forward" `Quick
      test_a_paused_instance_carries_its_last_value_forward;
    Alcotest.test_case "union_grid_keeps_every_observation" `Quick
      test_union_grid_keeps_every_observation;
    Alcotest.test_case "unsorted_and_duplicated_input_is_tolerated" `Quick
      test_unsorted_and_duplicated_input_is_tolerated;
    Alcotest.test_case "disjoint_windows_are_refused" `Quick test_disjoint_windows_are_refused;
    Alcotest.test_case "too_few_points_is_refused_rather_than_reported" `Quick
      test_too_few_points_is_refused_rather_than_reported;
    Alcotest.test_case "comparing_an_instance_with_itself_is_refused" `Quick
      test_comparing_an_instance_with_itself_is_refused;
    Alcotest.test_case "empty_curve_is_refused" `Quick test_empty_curve_is_refused;
    Alcotest.test_case "json_has_the_shape_the_dashboard_reads" `Quick
      test_json_has_the_shape_the_dashboard_reads;
  ]
