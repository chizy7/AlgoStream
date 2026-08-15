module R = Algostream_analytics.Rolling
module LA = Algostream_common_utils.Math_utils.LinearAlgebra

let test_rolling_mean_basic () =
  let m = R.Rolling_mean.create ~window:3 in
    Alcotest.(check (float 1e-9)) "after [1]" 1.0 (R.Rolling_mean.update m 1.0) ;
    Alcotest.(check (float 1e-9)) "after [1;2]" 1.5 (R.Rolling_mean.update m 2.0) ;
    Alcotest.(check (float 1e-9)) "after [1;2;3]" 2.0 (R.Rolling_mean.update m 3.0) ;
    Alcotest.(check (float 1e-9)) "after [2;3;4]" 3.0 (R.Rolling_mean.update m 4.0)


let test_rolling_var_matches_batch () =
  let n = 200 in
  let window = 50 in
  let recompute = 8 in
  let rv = R.Rolling_var.create ~window ~recompute_every:recompute in
  let rng = Random.State.make [| 17 |] in
  let last_window = Array.make window 0.0 in
  let idx = ref 0 in
  let count = ref 0 in
    for _ = 1 to n do
      let v = Random.State.float rng 100.0 in
      let _ = R.Rolling_var.update rv v in
        last_window.(!idx) <- v ;
        idx := (!idx + 1) mod window ;
        if !count < window then incr count
    done ;
    let actual = R.Rolling_var.value rv in
    let arr = Array.sub last_window 0 !count in
    let mean =
      let s = ref 0.0 in
        Array.iter (fun v -> s := !s +. v) arr ;
        !s /. float_of_int !count in
    let expected =
      let s = ref 0.0 in
        Array.iter (fun v -> s := !s +. ((v -. mean) ** 2.0)) arr ;
        !s /. float_of_int (!count - 1) in
      Alcotest.(check (float 1e-3)) "rolling var matches batch" expected actual


(* Property test: Rolling_corr converges to LinearAlgebra.correlation for a fully-buffered
   window. *)
let test_rolling_corr_matches_batch () =
  let n = 500 in
  let window = 256 in
  let recompute = 8 in
  let rc = R.Rolling_corr.create ~window ~recompute_every:recompute in
  let rng = Random.State.make [| 7 |] in
  let xs = Array.make window 0.0 in
  let ys = Array.make window 0.0 in
  let idx = ref 0 in
  let count = ref 0 in
    for _ = 1 to n do
      let x = Random.State.float rng 100.0 in
      let y = (0.7 *. x) +. Random.State.float rng 30.0 in
      let _ = R.Rolling_corr.update rc x y in
        xs.(!idx) <- x ;
        ys.(!idx) <- y ;
        idx := (!idx + 1) mod window ;
        if !count < window then incr count
    done ;
    let xs_b = Array.sub xs 0 !count in
    let ys_b = Array.sub ys 0 !count in
    let expected = LA.correlation xs_b ys_b in
    let actual = R.Rolling_corr.value rc in
      Alcotest.(check (float 0.05)) "rolling Pearson matches batch" expected actual


let test_rolling_corr_clamped () =
  let rc = R.Rolling_corr.create ~window:10 ~recompute_every:4 in
    for i = 1 to 30 do
      let x = float_of_int i in
      let y = float_of_int i in
      let _ = R.Rolling_corr.update rc x y in
        ()
    done ;
    let v = R.Rolling_corr.value rc in
      Alcotest.(check bool) "perfect corr clamped to 1.0" true (abs_float (v -. 1.0) < 1e-6)


let suite =
  [
    Alcotest.test_case "rolling_mean_basic" `Quick test_rolling_mean_basic;
    Alcotest.test_case "rolling_var_matches_batch" `Quick test_rolling_var_matches_batch;
    Alcotest.test_case "rolling_corr_matches_batch" `Quick test_rolling_corr_matches_batch;
    Alcotest.test_case "rolling_corr_clamped" `Quick test_rolling_corr_clamped;
  ]
