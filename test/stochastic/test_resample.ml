module Resample = Algostream_stochastic.Resample
module Rng = Algostream_rng.Rng
module Variate = Algostream_stochastic.Variate

let mean a = Array.fold_left ( +. ) 0.0 a /. float_of_int (Array.length a)

(* Lag-1 autocorrelation: the statistic that distinguishes the bootstrap variants. *)
let autocorr1 a =
  let n = Array.length a in
  let m = mean a in
  let num = ref 0.0 and den = ref 0.0 in
    for i = 0 to n - 2 do
      num := !num +. ((a.(i) -. m) *. (a.(i + 1) -. m))
    done ;
    for i = 0 to n - 1 do
      den := !den +. ((a.(i) -. m) *. (a.(i) -. m))
    done ;
    if !den <= 0.0 then 0.0 else !num /. !den


(* An AR(1) series with strong positive dependence — the structure the block variants must preserve
   and the iid variant must destroy. *)
let ar1_series ~n ~phi ~seed =
  let rng = Rng.create ~seed in
  let out = Array.make n 0.0 in
  let prev = ref 0.0 in
    for i = 0 to n - 1 do
      let v = (phi *. !prev) +. Variate.normal rng in
        out.(i) <- v ;
        prev := v
    done ;
    out


let test_iid_preserves_mean () =
  let data = ar1_series ~n:2000 ~phi:0.0 ~seed:1 in
  let rng = Rng.create ~seed:2 in
  let s = Resample.iid rng ~data ~n:2000 in
    Alcotest.(check int) "requested length" 2000 (Array.length s) ;
    Alcotest.(check bool)
      (Printf.sprintf "resampled mean %.4f near source mean %.4f" (mean s) (mean data))
      true
      (Float.abs (mean s -. mean data) < 0.15)


(* THE bootstrap property. iid destroys serial dependence; block variants keep it. Getting this
   backwards produces Monte Carlo drawdowns far too benign to be useful. *)
let test_block_preserves_autocorrelation_iid_destroys_it () =
  let data = ar1_series ~n:4000 ~phi:0.8 ~seed:3 in
  let source_ac = autocorr1 data in
  let rng = Rng.create ~seed:4 in
  let iid = Resample.iid rng ~data ~n:4000 in
  let block = Resample.circular_block rng ~data ~block_len:50 ~n:4000 in
  let stat = Resample.stationary rng ~data ~mean_block_len:50.0 ~n:4000 in
    Alcotest.(check bool)
      (Printf.sprintf "source autocorrelation %.3f is strong" source_ac)
      true (source_ac > 0.7) ;
    Alcotest.(check bool)
      (Printf.sprintf "iid destroys it (%.3f near zero)" (autocorr1 iid))
      true
      (Float.abs (autocorr1 iid) < 0.10) ;
    Alcotest.(check bool)
      (Printf.sprintf "circular block preserves it (%.3f)" (autocorr1 block))
      true
      (autocorr1 block > 0.6) ;
    Alcotest.(check bool)
      (Printf.sprintf "stationary bootstrap preserves it (%.3f)" (autocorr1 stat))
      true
      (autocorr1 stat > 0.6)


let test_circular_block_uses_every_observation () =
  (* With no wrap, observations near the ends are under-sampled; the circular variant fixes that. *)
  let data = Array.init 100 float_of_int in
  let rng = Rng.create ~seed:5 in
  let seen = Hashtbl.create 100 in
    for _ = 1 to 300 do
      let s = Resample.circular_block rng ~data ~block_len:10 ~n:100 in
        Array.iter (fun v -> Hashtbl.replace seen v ()) s
    done ;
    Alcotest.(check int) "every one of the 100 observations appears" 100 (Hashtbl.length seen)


let test_stationary_block_lengths_are_geometric () =
  (* Mean block length must match the parameter: count how often the sampled index breaks
     contiguity. *)
  let data = Array.init 1000 float_of_int in
  let rng = Rng.create ~seed:6 in
  let mean_b = 20.0 in
  let n = 100_000 in
  let s = Resample.stationary rng ~data ~mean_block_len:mean_b ~n in
  let breaks = ref 0 in
    for i = 1 to n - 1 do
      let expected = Float.rem (s.(i - 1) +. 1.0) 1000.0 in
        if Float.abs (s.(i) -. expected) > 1e-9 then incr breaks
    done ;
    let observed_mean_block = float_of_int n /. float_of_int (max 1 !breaks) in
      Alcotest.(check bool)
        (Printf.sprintf "observed mean block %.2f near the requested %.1f" observed_mean_block
           mean_b)
        true
        (Float.abs (observed_mean_block -. mean_b) < 4.0)


(* joint_index is what keeps a pairs strategy tradeable under resampling: applying ONE index array
   to both legs preserves their relationship, whereas resampling each leg independently destroys
   it. *)
let test_joint_index_preserves_cross_correlation () =
  let rng = Rng.create ~seed:7 in
  let n = 4000 in
  let x = Array.init n (fun _ -> Variate.normal rng) in
  (* y is strongly related to x. *)
  let y =
    Array.mapi (fun i v -> (0.9 *. v) +. (0.2 *. Variate.normal rng) +. (0.0 *. float_of_int i)) x
  in
  let corr a b =
    let ma = mean a and mb = mean b in
    let sab = ref 0.0 and saa = ref 0.0 and sbb = ref 0.0 in
      for i = 0 to Array.length a - 1 do
        let da = a.(i) -. ma and db = b.(i) -. mb in
          sab := !sab +. (da *. db) ;
          saa := !saa +. (da *. da) ;
          sbb := !sbb +. (db *. db)
      done ;
      !sab /. sqrt (!saa *. !sbb) in
  let source = corr x y in
  (* Right way: one shared index array. *)
  let idx = Resample.joint_index rng ~n_source:n ~n ~block_len:20 in
  let xj = Resample.take ~data:x ~idx and yj = Resample.take ~data:y ~idx in
  (* Wrong way: resample each leg independently. *)
  let xi = Resample.circular_block rng ~data:x ~block_len:20 ~n in
  let yi = Resample.circular_block rng ~data:y ~block_len:20 ~n in
    Alcotest.(check bool)
      (Printf.sprintf "source correlation %.3f is strong" source)
      true (source > 0.9) ;
    Alcotest.(check bool)
      (Printf.sprintf "joint_index preserves it (%.3f)" (corr xj yj))
      true
      (corr xj yj > 0.85) ;
    Alcotest.(check bool)
      (Printf.sprintf "independent resampling destroys it (%.3f)" (corr xi yi))
      true
      (Float.abs (corr xi yi) < 0.2)


let test_take_rejects_out_of_range () =
  Alcotest.(check bool)
    "raises on a bad index" true
    (try
       ignore (Resample.take ~data:[| 1.0; 2.0 |] ~idx:[| 5 |]) ;
       false
     with Invalid_argument _ -> true)


let test_rule_of_thumb () =
  Alcotest.(check int) "n=1000 gives 10" 10 (Resample.rule_of_thumb ~n:1000) ;
  Alcotest.(check int) "n=1 floors at 1" 1 (Resample.rule_of_thumb ~n:1) ;
  Alcotest.(check int) "n=0 floors at 1" 1 (Resample.rule_of_thumb ~n:0)


let test_permute_is_a_permutation () =
  let a = Array.init 200 (fun i -> i) in
  let rng = Rng.create ~seed:8 in
  let p = Resample.permute rng a in
    Alcotest.(check int) "same length" 200 (Array.length p) ;
    Alcotest.(check (array int)) "original untouched" (Array.init 200 (fun i -> i)) a ;
    let sorted = Array.copy p in
      Array.sort compare sorted ;
      Alcotest.(check (array int)) "same multiset" a sorted


let test_sign_flip_preserves_magnitudes () =
  let a = [| 1.0; -2.0; 3.0 |] in
  let rng = Rng.create ~seed:9 in
  let f = Resample.sign_flip rng a in
    Array.iteri
      (fun i v ->
        Alcotest.(check (float 1e-12))
          (Printf.sprintf "magnitude %d preserved" i)
          (Float.abs a.(i))
          (Float.abs v))
      f


let test_empty_data_raises () =
  let rng = Rng.create ~seed:10 in
    Alcotest.(check bool)
      "iid on empty data raises" true
      (try
         ignore (Resample.iid rng ~data:[||] ~n:10) ;
         false
       with Invalid_argument _ -> true)


let suite =
  [
    Alcotest.test_case "iid_preserves_mean" `Quick test_iid_preserves_mean;
    Alcotest.test_case "block_preserves_autocorrelation_iid_destroys_it" `Quick
      test_block_preserves_autocorrelation_iid_destroys_it;
    Alcotest.test_case "circular_block_uses_every_observation" `Quick
      test_circular_block_uses_every_observation;
    Alcotest.test_case "stationary_block_lengths_are_geometric" `Quick
      test_stationary_block_lengths_are_geometric;
    Alcotest.test_case "joint_index_preserves_cross_correlation" `Quick
      test_joint_index_preserves_cross_correlation;
    Alcotest.test_case "take_rejects_out_of_range" `Quick test_take_rejects_out_of_range;
    Alcotest.test_case "rule_of_thumb" `Quick test_rule_of_thumb;
    Alcotest.test_case "permute_is_a_permutation" `Quick test_permute_is_a_permutation;
    Alcotest.test_case "sign_flip_preserves_magnitudes" `Quick test_sign_flip_preserves_magnitudes;
    Alcotest.test_case "empty_data_raises" `Quick test_empty_data_raises;
  ]
