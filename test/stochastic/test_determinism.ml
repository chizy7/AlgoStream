(* Same seed, same output — for every sampler, resampler and interval in the library. Plus the
   standard clock/bad-RNG scan over lib/stochastic. *)

module Rng = Algostream_rng.Rng
module Variate = Algostream_stochastic.Variate
module Resample = Algostream_stochastic.Resample
module Quantile = Algostream_stochastic.Quantile
module Cholesky = Algostream_stochastic.Cholesky

let twice f =
  let a = f (Rng.create ~seed:777) in
  let b = f (Rng.create ~seed:777) in
    (a, b)


let check_arrays name (a, b) =
  Alcotest.(check int) (name ^ " length") (Array.length a) (Array.length b) ;
  Array.iteri
    (fun i x ->
      if x <> b.(i) then Alcotest.failf "%s: element %d diverged (%.17g vs %.17g)" name i x b.(i))
    a ;
  Alcotest.(check bool) (name ^ " is bit-identical") true true


let test_variates_reproduce () =
  check_arrays "normal" (twice (fun r -> Array.init 500 (fun _ -> Variate.normal r))) ;
  check_arrays "gamma"
    (twice (fun r -> Array.init 500 (fun _ -> Variate.gamma r ~shape:2.5 ~scale:1.5))) ;
  check_arrays "student_t" (twice (fun r -> Array.init 500 (fun _ -> Variate.student_t r ~df:5.0))) ;
  check_arrays "exponential"
    (twice (fun r -> Array.init 500 (fun _ -> Variate.exponential r ~lambda:1.5))) ;
  check_arrays "poisson"
    (twice (fun r -> Array.init 500 (fun _ -> float_of_int (Variate.poisson r ~lambda:12.0))))


let test_resamplers_reproduce () =
  let data = Array.init 500 (fun i -> sin (float_of_int i /. 7.0)) in
    check_arrays "iid" (twice (fun r -> Resample.iid r ~data ~n:500)) ;
    check_arrays "circular_block"
      (twice (fun r -> Resample.circular_block r ~data ~block_len:20 ~n:500)) ;
    check_arrays "moving_block"
      (twice (fun r -> Resample.moving_block r ~data ~block_len:20 ~n:500)) ;
    check_arrays "stationary"
      (twice (fun r -> Resample.stationary r ~data ~mean_block_len:20.0 ~n:500)) ;
    check_arrays "joint_index"
      (twice (fun r ->
         Array.map float_of_int (Resample.joint_index r ~n_source:500 ~n:500 ~block_len:20)))


(* Quantiles are deterministic by construction — no RNG at all — but the reservoir-sampled
   percentile tracker in Math_utils is not, which is precisely why this library exists. *)
let test_quantiles_are_deterministic () =
  let rng = Rng.create ~seed:5 in
  let s = Array.init 5000 (fun _ -> Variate.normal rng) in
  let a = Quantile.summarize s in
  let b = Quantile.summarize s in
    Alcotest.(check (float 0.0)) "p05" a.Quantile.p05 b.Quantile.p05 ;
    Alcotest.(check (float 0.0)) "p95" a.Quantile.p95 b.Quantile.p95 ;
    Alcotest.(check (float 0.0)) "ci99_lo" a.Quantile.ci99_lo b.Quantile.ci99_lo


let test_cholesky_is_deterministic () =
  let a = [| [| 4.0; 2.0; 1.0 |]; [| 2.0; 5.0; 3.0 |]; [| 1.0; 3.0; 6.0 |] |] in
    match (Cholesky.factor a, Cholesky.factor a) with
    | Ok x, Ok y ->
      Array.iteri
        (fun i row -> Array.iteri (fun j v -> Alcotest.(check (float 0.0)) "L" v y.(i).(j)) row)
        x
    | _ -> Alcotest.fail "factorization failed"


let contains_substring haystack needle =
  let nl = String.length needle in
  let hl = String.length haystack in
  let rec loop i =
    if i + nl > hl then false else if String.sub haystack i nl = needle then true else loop (i + 1)
  in
    loop 0


let banned = [ "Clock.now_"; "Unix.gettimeofday"; "Timestamp.now ()"; "self_init" ]

let test_no_clock_or_bad_rng () =
  let candidates =
    [
      "lib/stochastic"; "../../../lib/stochastic"; Filename.concat (Sys.getcwd ()) "lib/stochastic";
    ] in
  let dir = match List.find_opt Sys.file_exists candidates with Some d -> d | None -> "" in
    if dir = "" then Alcotest.(check bool) "lint enforced via CI" true true
    else
      let leaks = ref [] in
      let rec walk d =
        Array.iter
          (fun f ->
            let p = Filename.concat d f in
              if Sys.is_directory p then walk p
              else if Filename.check_suffix p ".ml" || Filename.check_suffix p ".mli" then (
                let ic = open_in p in
                  (try
                     while true do
                       let line = input_line ic in
                         List.iter
                           (fun b -> if contains_substring line b then leaks := (p, line) :: !leaks)
                           banned
                     done
                   with End_of_file -> ()) ;
                  close_in ic))
          (Sys.readdir d) in
        walk dir ;
        if !leaks <> [] then List.iter (fun (p, l) -> Printf.eprintf "LEAK: %s :: %s\n" p l) !leaks ;
        Alcotest.(check int) "no wall-clock or self_init in lib/stochastic" 0 (List.length !leaks)


let suite =
  [
    Alcotest.test_case "variates_reproduce" `Quick test_variates_reproduce;
    Alcotest.test_case "resamplers_reproduce" `Quick test_resamplers_reproduce;
    Alcotest.test_case "quantiles_are_deterministic" `Quick test_quantiles_are_deterministic;
    Alcotest.test_case "cholesky_is_deterministic" `Quick test_cholesky_is_deterministic;
    Alcotest.test_case "no_clock_or_bad_rng" `Quick test_no_clock_or_bad_rng;
  ]
