module Opt = Algostream_optimization
module CV = Algostream_optimization.Cross_validation

let day = 86_400_000_000_000L

let lo = 0L

let hi = Int64.mul day 100L

(* The property the whole module exists for: no training observation may sit inside a test interval
   or inside the embargo that follows it. Naive k-fold violates this and inflates out-of-sample
   Sharpe; these assertions are what prove we do not. *)
let test_purged_kfold_is_leak_free () =
  let embargo_ns = Int64.mul day 2L in
  let splits = CV.splits (CV.Purged_kfold { k = 5; embargo_ns }) ~lo_ns:lo ~hi_ns:hi in
    Alcotest.(check int) "five folds" 5 (Array.length splits) ;
    Array.iter
      (fun s ->
        Alcotest.(check bool)
          (Printf.sprintf "split %d has no train/test overlap or embargo violation" s.CV.index)
          true (CV.is_leak_free s ~embargo_ns))
      splits


let test_cpcv_is_leak_free () =
  let embargo_ns = Int64.mul day 1L in
  let scheme = CV.Combinatorial_purged { n_groups = 6; n_test_groups = 2; embargo_ns } in
  let splits = CV.splits scheme ~lo_ns:lo ~hi_ns:hi in
    Array.iter
      (fun s ->
        Alcotest.(check bool)
          (Printf.sprintf "cpcv split %d is leak free" s.CV.index)
          true (CV.is_leak_free s ~embargo_ns))
      splits


(* C(6,2) = 15. The count matters: CPCV's value is that it yields many out-of-sample paths, and a
   caller sizing a run needs the number to be what the formula says. *)
let test_cpcv_split_count () =
  let scheme = CV.Combinatorial_purged { n_groups = 6; n_test_groups = 2; embargo_ns = 0L } in
    Alcotest.(check int) "C(6,2) = 15" 15 (CV.n_splits scheme) ;
    Alcotest.(check int)
      "and that many splits are built" 15
      (Array.length (CV.splits scheme ~lo_ns:lo ~hi_ns:hi)) ;
    let scheme2 = CV.Combinatorial_purged { n_groups = 10; n_test_groups = 3; embargo_ns = 0L } in
      Alcotest.(check int) "C(10,3) = 120" 120 (CV.n_splits scheme2)


let test_test_windows_tile_the_range () =
  let splits = CV.splits (CV.Purged_kfold { k = 4; embargo_ns = 0L }) ~lo_ns:lo ~hi_ns:hi in
  let total =
    Array.fold_left
      (fun acc s -> Array.fold_left (fun a (x, y) -> Int64.add a (Int64.sub y x)) acc s.CV.test)
      0L splits in
    Alcotest.(check int64) "test windows exactly cover the range" (Int64.sub hi lo) total


(* Without an embargo, the fold immediately after the test window is legitimately usable; with one,
   it must be dropped. The training set therefore has to shrink. *)
let test_embargo_shrinks_training_set () =
  let span s = Array.fold_left (fun a (x, y) -> Int64.add a (Int64.sub y x)) 0L s.CV.train in
  let no_embargo = CV.splits (CV.Purged_kfold { k = 5; embargo_ns = 0L }) ~lo_ns:lo ~hi_ns:hi in
  let with_embargo =
    CV.splits (CV.Purged_kfold { k = 5; embargo_ns = Int64.mul day 30L }) ~lo_ns:lo ~hi_ns:hi in
  let a = Array.fold_left (fun acc s -> Int64.add acc (span s)) 0L no_embargo in
  let b = Array.fold_left (fun acc s -> Int64.add acc (span s)) 0L with_embargo in
    Alcotest.(check bool)
      (Printf.sprintf "embargoed training total %Ld < unembargoed %Ld" b a)
      true
      (Int64.compare b a < 0)


let suite =
  [
    Alcotest.test_case "purged_kfold_is_leak_free" `Quick test_purged_kfold_is_leak_free;
    Alcotest.test_case "cpcv_is_leak_free" `Quick test_cpcv_is_leak_free;
    Alcotest.test_case "cpcv_split_count" `Quick test_cpcv_split_count;
    Alcotest.test_case "test_windows_tile_the_range" `Quick test_test_windows_tile_the_range;
    Alcotest.test_case "embargo_shrinks_training_set" `Quick test_embargo_shrinks_training_set;
  ]
