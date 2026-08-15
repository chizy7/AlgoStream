module Rng = Algostream_rng.Rng

let test_uniform_in_unit_interval () =
  let r = Rng.create ~seed:11 in
  let lo = ref infinity and hi = ref neg_infinity and saw_one = ref false in
    for _ = 1 to 2_000_000 do
      let u = Rng.uniform r in
        if u < !lo then lo := u ;
        if u > !hi then hi := u ;
        if u >= 1.0 then saw_one := true
    done ;
    Alcotest.(check bool) (Printf.sprintf "min %.10g >= 0" !lo) true (!lo >= 0.0) ;
    Alcotest.(check bool) "uniform never returns 1.0" false !saw_one ;
    Alcotest.(check bool) (Printf.sprintf "max %.10g < 1" !hi) true (!hi < 1.0)


(* The [log 0] regression. [Math_utils.FastRandom.uniform_float] can return exactly 0.0 and its
   Box-Muller does an unclamped [log], which yields -inf and then nan. [uniform_pos] must never
   return a boundary value. *)
let test_uniform_pos_is_open () =
  let r = Rng.create ~seed:13 in
  let saw_zero = ref false and saw_one = ref false and any_nan = ref false in
    for _ = 1 to 2_000_000 do
      let u = Rng.uniform_pos r in
        if u <= 0.0 then saw_zero := true ;
        if u >= 1.0 then saw_one := true ;
        if Float.is_nan (log u) then any_nan := true
    done ;
    Alcotest.(check bool) "uniform_pos never returns 0.0" false !saw_zero ;
    Alcotest.(check bool) "uniform_pos never returns 1.0" false !saw_one ;
    Alcotest.(check bool) "log (uniform_pos) is always finite" false !any_nan


let test_uniform_mean_and_variance () =
  let r = Rng.create ~seed:17 in
  let n = 1_000_000 in
  let s = ref 0.0 and ss = ref 0.0 in
    for _ = 1 to n do
      let u = Rng.uniform r in
        s := !s +. u ;
        ss := !ss +. (u *. u)
    done ;
    let nf = float_of_int n in
    let m = !s /. nf in
    let v = (!ss /. nf) -. (m *. m) in
      (* U(0,1) has mean 1/2 and variance 1/12; SE of the mean at n = 1e6 is ~2.9e-4. *)
      Alcotest.(check bool) (Printf.sprintf "mean %.6f ~ 0.5" m) true (Float.abs (m -. 0.5) < 0.002) ;
      Alcotest.(check bool)
        (Printf.sprintf "variance %.6f ~ 0.08333" v)
        true
        (Float.abs (v -. (1.0 /. 12.0)) < 0.002)


(* A non-power-of-two bound is where modulo bias shows up. Chi-squared over 7 buckets. *)
let test_int_below_unbiased () =
  let r = Rng.create ~seed:19 in
  let k = 7 in
  let n = 700_000 in
  let counts = Array.make k 0 in
    for _ = 1 to n do
      let i = Rng.int_below r k in
        if i < 0 || i >= k then Alcotest.fail (Printf.sprintf "int_below returned %d" i) ;
        counts.(i) <- counts.(i) + 1
    done ;
    let expected = float_of_int n /. float_of_int k in
    let chi2 =
      Array.fold_left
        (fun acc c ->
          let d = float_of_int c -. expected in
            acc +. (d *. d /. expected))
        0.0 counts in
      (* 6 df, 99.9th percentile is 22.46. *)
      Alcotest.(check bool)
        (Printf.sprintf "chi2 = %.3f < 22.46 (6 df, p=0.001)" chi2)
        true (chi2 < 22.46)


let test_int_below_rejects_nonpositive () =
  let r = Rng.create ~seed:23 in
    Alcotest.check_raises "n = 0 raises" (Invalid_argument "Rng.int_below: n must be positive")
      (fun () -> ignore (Rng.int_below r 0)) ;
    Alcotest.check_raises "n < 0 raises" (Invalid_argument "Rng.int_below: n must be positive")
      (fun () -> ignore (Rng.int_below r (-3)))


let test_int_below_one () =
  let r = Rng.create ~seed:29 in
    for _ = 1 to 1000 do
      Alcotest.(check int) "int_below 1 is always 0" 0 (Rng.int_below r 1)
    done


(* All 24 permutations of a 4-element array should appear with equal frequency. *)
let test_shuffle_uniform () =
  let r = Rng.create ~seed:31 in
  let tbl = Hashtbl.create 24 in
  let n = 240_000 in
    for _ = 1 to n do
      let a = [| 0; 1; 2; 3 |] in
        Rng.shuffle r a ;
        let key = Array.fold_left (fun acc x -> (acc * 10) + x) 0 a in
          Hashtbl.replace tbl key (1 + try Hashtbl.find tbl key with Not_found -> 0)
    done ;
    Alcotest.(check int) "all 24 permutations observed" 24 (Hashtbl.length tbl) ;
    let expected = float_of_int n /. 24.0 in
    let chi2 =
      Hashtbl.fold
        (fun _ c acc ->
          let d = float_of_int c -. expected in
            acc +. (d *. d /. expected))
        tbl 0.0 in
      (* 23 df, 99.9th percentile is 49.73. *)
      Alcotest.(check bool)
        (Printf.sprintf "chi2 = %.3f < 49.73 (23 df, p=0.001)" chi2)
        true (chi2 < 49.73)


let test_uniform_range () =
  let r = Rng.create ~seed:37 in
    for _ = 1 to 10_000 do
      let x = Rng.uniform_range r ~lo:(-5.0) ~hi:3.0 in
        if x < -5.0 || x >= 3.0 then Alcotest.fail (Printf.sprintf "out of range: %g" x)
    done ;
    Alcotest.(check (float 0.0))
      "degenerate range returns lo" 2.0
      (Rng.uniform_range r ~lo:2.0 ~hi:2.0)


let suite =
  [
    Alcotest.test_case "uniform_in_unit_interval" `Quick test_uniform_in_unit_interval;
    Alcotest.test_case "uniform_pos_is_open" `Quick test_uniform_pos_is_open;
    Alcotest.test_case "uniform_mean_and_variance" `Quick test_uniform_mean_and_variance;
    Alcotest.test_case "int_below_unbiased" `Quick test_int_below_unbiased;
    Alcotest.test_case "int_below_rejects_nonpositive" `Quick test_int_below_rejects_nonpositive;
    Alcotest.test_case "int_below_one" `Quick test_int_below_one;
    Alcotest.test_case "shuffle_uniform" `Quick test_shuffle_uniform;
    Alcotest.test_case "uniform_range" `Quick test_uniform_range;
  ]
