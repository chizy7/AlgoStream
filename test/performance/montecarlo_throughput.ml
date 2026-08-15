(** Monte Carlo throughput and parallel speedup.

    Publishes the MEASURED speedup at 1/2/4/8 domains rather than claiming linear scaling. OCaml 5
    has a shared heap and the metric pipeline allocates, so the realistic expectation is 4-6x on 8
    cores; the number this bench prints is the one the guide quotes. *)

module MC = Algostream_montecarlo
module Perf = Algostream_performance
module Rng = Algostream_rng.Rng
module Variate = Algostream_stochastic.Variate
module Clock = Algostream_common_utils.Time_utils.Clock

let n_runs = 4000

let n_obs = 1000

(* Measured release-profile: ~1,340 runs/s single-domain, ~5,650 at 8 domains (4.2x). *)
let path_floor = 700.0

let parse_args () =
  let json = ref None in
  let i = ref 1 in
    while !i < Array.length Sys.argv do
      (match Sys.argv.(!i) with
      | "--json" when !i + 1 < Array.length Sys.argv ->
        json := Some Sys.argv.(!i + 1) ;
        incr i
      | "--help" ->
        print_endline "Usage: montecarlo_throughput [--json PATH]" ;
        exit 0
      | other ->
        Printf.eprintf "unknown arg: %s\n" other ;
        exit 2) ;
      incr i
    done ;
    !json


let returns_fixture () =
  let rng = Rng.create ~seed:99 in
    Array.init n_obs (fun _ -> 0.0003 +. (0.012 *. Variate.normal rng))


let timed_run ~returns ~n_domains =
  let t0 = Clock.now_monotonic_ns () in
  let s = MC.Engine.run_paths ~returns ~n_runs ~root_seed:7L ~n_domains ~periods_per_year:252.0 () in
  let t1 = Clock.now_monotonic_ns () in
    ignore s ;
    Int64.sub t1 t0


let main () =
  let json_path = parse_args () in
  let returns = returns_fixture () in
  let elapsed_by_domains = List.map (fun d -> (d, timed_run ~returns ~n_domains:d)) [ 1; 2; 4; 8 ] in
  let base = List.assoc 1 elapsed_by_domains in
  let base_rps = float_of_int n_runs /. (Int64.to_float base /. 1e9) in
    List.iter
      (fun (d, e) ->
        let rps = float_of_int n_runs /. (Int64.to_float e /. 1e9) in
        let speedup = Int64.to_float base /. Int64.to_float e in
          Printf.printf
            "mc.path_level: domains=%d runs=%d elapsed=%Ldms %.0f runs/s speedup=%.2fx\n" d n_runs
            (Int64.div e 1_000_000L) rps speedup)
      elapsed_by_domains ;
    let best =
      List.fold_left
        (fun acc (_, e) -> if Int64.compare e acc < 0 then e else acc)
        base elapsed_by_domains in
    let best_speedup = Int64.to_float base /. Int64.to_float best in
      Printf.printf "mc.best_speedup: %.2fx (measured, not assumed linear)\n" best_speedup ;
      if base_rps < path_floor then (
        Printf.eprintf "REGRESSION: single-domain %.0f runs/s is below the floor of %.0f\n" base_rps
          path_floor ;
        exit 1) ;
      match json_path with
      | None -> ()
      | Some path ->
        let ns_per_run d = Int64.div (List.assoc d elapsed_by_domains) (Int64.of_int n_runs) in
        let oc = open_out path in
          Printf.fprintf oc "[\n" ;
          Printf.fprintf oc
            "  \
             {\"name\":\"mc.path_level_1domain.ns_per_run\",\"unit\":\"ns\",\"value\":%Ld,\"extra\":\"%.0f \
             runs/s\"},\n"
            (ns_per_run 1) base_rps ;
          Printf.fprintf oc
            "  \
             {\"name\":\"mc.path_level_8domain.ns_per_run\",\"unit\":\"ns\",\"value\":%Ld,\"extra\":\"speedup=%.2fx\"}\n"
            (ns_per_run 8) best_speedup ;
          Printf.fprintf oc "]\n" ;
          close_out oc ;
          Printf.printf "wrote %s\n" path


let () = main ()
