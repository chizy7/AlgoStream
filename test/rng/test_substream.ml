(* The regression suite for the defect that motivated this library.

   [Math_utils.FastRandom.create_xorshift] seeds only the first of four state words and leaves the
   other three at fixed constants, so streams from nearby seeds stay correlated for many draws. A
   Monte Carlo batch seeds runs 0, 1, 2, ... n, which is precisely the adjacent-seed pattern. These
   tests fail loudly against that construction and pass against SplitMix64 expansion. *)

module Rng = Algostream_rng.Rng

let draws rng n = Array.init n (fun _ -> Rng.uniform rng)

let mean a = Array.fold_left ( +. ) 0.0 a /. float_of_int (Array.length a)

let correlation x y =
  let n = Array.length x in
  let mx = mean x and my = mean y in
  let sxy = ref 0.0 and sxx = ref 0.0 and syy = ref 0.0 in
    for i = 0 to n - 1 do
      let dx = x.(i) -. mx and dy = y.(i) -. my in
        sxy := !sxy +. (dx *. dy) ;
        sxx := !sxx +. (dx *. dx) ;
        syy := !syy +. (dy *. dy)
    done ;
    if !sxx <= 0.0 || !syy <= 0.0 then 0.0 else !sxy /. sqrt (!sxx *. !syy)


(* THE test. Adjacent run indices must be uncorrelated. Under the old xorshift seeding, streams from
   seeds k and k+1 share three of four state words and correlate strongly. *)
let test_adjacent_substreams_uncorrelated () =
  let worst = ref 0.0 in
  let worst_pair = ref (0, 0) in
    for k = 0 to 63 do
      let a = draws (Rng.substream ~root_seed:42L ~index:k) 2000 in
      let b = draws (Rng.substream ~root_seed:42L ~index:(k + 1)) 2000 in
      let c = Float.abs (correlation a b) in
        if c > !worst then (
          worst := c ;
          worst_pair := (k, k + 1))
    done ;
    Alcotest.(check bool)
      (Printf.sprintf "max |corr| over 64 adjacent substream pairs = %.4f (worst pair %d/%d) < 0.10"
         !worst (fst !worst_pair) (snd !worst_pair))
      true (!worst < 0.10)


(* First outputs must differ across streams. The old construction produced an identical second and
   third output for every seed, because the seed had not yet propagated through the state. *)
let test_first_outputs_distinct () =
  let n_streams = 4096 in
  let tbl = Hashtbl.create n_streams in
  let collisions = ref 0 in
    for k = 0 to n_streams - 1 do
      let r = Rng.substream ~root_seed:7L ~index:k in
      (* Fingerprint the first three outputs jointly. *)
      let f = (Rng.bits r, Rng.bits r, Rng.bits r) in
        if Hashtbl.mem tbl f then incr collisions else Hashtbl.replace tbl f ()
    done ;
    Alcotest.(check int) "no two substreams share their first three outputs" 0 !collisions


let test_substream_is_pure () =
  (* Order of construction, and any intervening draws, must not affect the result. *)
  let a = draws (Rng.substream ~root_seed:99L ~index:5) 32 in
  let noise = Rng.substream ~root_seed:99L ~index:0 in
    ignore (draws noise 1000) ;
    let b = draws (Rng.substream ~root_seed:99L ~index:5) 32 in
      Array.iteri (fun i x -> Alcotest.(check (float 0.0)) (Printf.sprintf "draw %d" i) x b.(i)) a


let test_root_seed_separates () =
  let a = draws (Rng.substream ~root_seed:1L ~index:0) 2000 in
  let b = draws (Rng.substream ~root_seed:2L ~index:0) 2000 in
  let c = Float.abs (correlation a b) in
    Alcotest.(check bool)
      (Printf.sprintf "adjacent root seeds uncorrelated (|corr| = %.4f < 0.10)" c)
      true (c < 0.10)


(* Seed 0 gave the old xorshift a partially-zero state. *)
let test_zero_and_negative_seeds () =
  let z = draws (Rng.create ~seed:0) 1000 in
  let neg = draws (Rng.create ~seed:(-12345)) 1000 in
  let mz = mean z and mn = mean neg in
    Alcotest.(check bool)
      (Printf.sprintf "seed 0 mean = %.4f within [0.45, 0.55]" mz)
      true
      (mz > 0.45 && mz < 0.55) ;
    Alcotest.(check bool)
      (Printf.sprintf "negative seed mean = %.4f within [0.45, 0.55]" mn)
      true
      (mn > 0.45 && mn < 0.55)


let test_copy_reproduces () =
  let r = Rng.create ~seed:2024 in
    ignore (draws r 17) ;
    let c = Rng.copy r in
    let a = draws r 64 in
    let b = draws c 64 in
      Array.iteri (fun i x -> Alcotest.(check (float 0.0)) "copy matches" x b.(i)) a


let test_split_diverges () =
  let r = Rng.create ~seed:5 in
  let s = Rng.split r in
  let a = draws r 2000 in
  let b = draws s 2000 in
  let c = Float.abs (correlation a b) in
    Alcotest.(check bool)
      (Printf.sprintf "split stream uncorrelated with parent (|corr| = %.4f < 0.10)" c)
      true (c < 0.10)


let suite =
  [
    Alcotest.test_case "adjacent_substreams_uncorrelated" `Quick
      test_adjacent_substreams_uncorrelated;
    Alcotest.test_case "first_outputs_distinct" `Quick test_first_outputs_distinct;
    Alcotest.test_case "substream_is_pure" `Quick test_substream_is_pure;
    Alcotest.test_case "root_seed_separates" `Quick test_root_seed_separates;
    Alcotest.test_case "zero_and_negative_seeds" `Quick test_zero_and_negative_seeds;
    Alcotest.test_case "copy_reproduces" `Quick test_copy_reproduces;
    Alcotest.test_case "split_diverges" `Quick test_split_diverges;
  ]
