(* Determinism for the Monte Carlo layer. The headline property — a batch summary that does not
   depend on core count — plus the standard clock-leak scan, extended here to also ban
   Math_utils.FastRandom and Random.self_init: a simulation layer that reached for either would be
   irreproducible in a way no other test would catch. *)

module MC = Algostream_montecarlo
module Rng = Algostream_rng.Rng
module Quantile = Algostream_stochastic.Quantile

let returns_fixture () =
  let rng = Rng.create ~seed:404 in
    Array.init 512 (fun _ -> 0.0004 +. (0.01 *. Algostream_stochastic.Variate.normal rng))


let test_run_paths_reproduces () =
  let returns = returns_fixture () in
  let go () =
    MC.Engine.run_paths ~returns ~n_runs:200 ~root_seed:5150L ~n_domains:1 ~periods_per_year:252.0
      () in
  let a = go () in
  let b = go () in
    Array.iteri
      (fun i (name, da) ->
        let nb, db = b.MC.Engine.per_metric.(i) in
          Alcotest.(check string) "metric name" name nb ;
          Alcotest.(check (float 1e-12)) (name ^ ".mean") da.Quantile.mean db.Quantile.mean ;
          Alcotest.(check (float 1e-12)) (name ^ ".p05") da.Quantile.p05 db.Quantile.p05 ;
          Alcotest.(check (float 1e-12)) (name ^ ".p95") da.Quantile.p95 db.Quantile.p95)
      a.MC.Engine.per_metric


(* Same batch, different core counts, identical summary. *)
let test_run_paths_core_count_independent () =
  let returns = returns_fixture () in
  let go nd =
    MC.Engine.run_paths ~returns ~n_runs:200 ~root_seed:9L ~n_domains:nd ~periods_per_year:252.0 ()
  in
  let base = go 1 in
    List.iter
      (fun nd ->
        let got = go nd in
          Array.iteri
            (fun i (name, d) ->
              let _, dg = got.MC.Engine.per_metric.(i) in
                Alcotest.(check (float 1e-12))
                  (Printf.sprintf "%s.mean at %d domains" name nd)
                  d.Quantile.mean dg.Quantile.mean ;
                Alcotest.(check (float 1e-12))
                  (Printf.sprintf "%s.p05 at %d domains" name nd)
                  d.Quantile.p05 dg.Quantile.p05)
            base.MC.Engine.per_metric)
      [ 2; 4; 8 ] ;
    Alcotest.(check bool) "summary identical at 1, 2, 4 and 8 domains" true true


let test_generator_is_pure_in_rng () =
  let series = MC.Generator.default_series ~symbol:"SYN" ~s0:100.0 in
  let g = MC.Generator.Gbm { mu = 0.0; sigma = 0.2; dt = 0.004; series } in
  let build () =
    let rng = Rng.substream ~root_seed:31337L ~index:11 in
    let ds = MC.Generator.build g ~rng ~n_steps:200 in
      Array.map
        (fun r -> match r with Algostream_backtest.Data_source.Tick t -> t.price | _ -> 0.0)
        (Algostream_backtest.Data_source.to_array ds) in
  let a = build () in
  let b = build () in
    Array.iteri (fun i x -> Alcotest.(check (float 0.0)) (Printf.sprintf "price %d" i) x b.(i)) a


let contains_substring haystack needle =
  let nl = String.length needle in
  let hl = String.length haystack in
  let rec loop i =
    if i + nl > hl then false else if String.sub haystack i nl = needle then true else loop (i + 1)
  in
    loop 0


let banned = [ "Clock.now_"; "Unix.gettimeofday"; "Timestamp.now ()"; "FastRandom"; "self_init" ]

let scan dir =
  let leaks = ref [] in
  let rec walk d =
    if Sys.file_exists d && Sys.is_directory d then
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
                         (fun b ->
                           if contains_substring line b then leaks := (p, b, line) :: !leaks)
                         banned
                   done
                 with End_of_file -> ()) ;
                close_in ic))
        (Sys.readdir d) in
    walk dir ;
    !leaks


let check_dir label rel =
  let candidates = [ rel; "../../../" ^ rel; Filename.concat (Sys.getcwd ()) rel ] in
  let dir = match List.find_opt Sys.file_exists candidates with Some d -> d | None -> "" in
    if dir = "" then Alcotest.(check bool) "lint enforced via CI" true true
    else
      let leaks = scan dir in
        if leaks <> [] then
          List.iter (fun (p, b, l) -> Printf.eprintf "BANNED (%s): %s :: %s\n" b p l) leaks ;
        Alcotest.(check int) label 0 (List.length leaks)


let test_no_clock_or_bad_rng_in_montecarlo () =
  check_dir "no wall-clock, FastRandom or self_init in lib/montecarlo" "lib/montecarlo"


let test_no_clock_or_bad_rng_in_optimization () =
  check_dir "no wall-clock, FastRandom or self_init in lib/optimization" "lib/optimization"


let test_no_bad_rng_in_stochastic () =
  check_dir "no wall-clock, FastRandom or self_init in lib/stochastic" "lib/stochastic"


let suite =
  [
    Alcotest.test_case "run_paths_reproduces" `Quick test_run_paths_reproduces;
    Alcotest.test_case "run_paths_core_count_independent" `Quick
      test_run_paths_core_count_independent;
    Alcotest.test_case "generator_is_pure_in_rng" `Quick test_generator_is_pure_in_rng;
    Alcotest.test_case "no_clock_or_bad_rng_in_montecarlo" `Quick
      test_no_clock_or_bad_rng_in_montecarlo;
    Alcotest.test_case "no_clock_or_bad_rng_in_optimization" `Quick
      test_no_clock_or_bad_rng_in_optimization;
    Alcotest.test_case "no_bad_rng_in_stochastic" `Quick test_no_bad_rng_in_stochastic;
  ]
