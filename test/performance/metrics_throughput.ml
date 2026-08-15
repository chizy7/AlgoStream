(** Performance-analytics throughput.

    The Monte Carlo worker calls Metrics.of_nav once per run, so its cost multiplies by the run
    count — at 10,000 runs a millisecond here is ten seconds of wall clock. Drawdown episode
    extraction is measured separately because it is the one genuinely new algorithm. *)

module Perf = Algostream_performance
module Rng = Algostream_rng.Rng
module Variate = Algostream_stochastic.Variate
module Clock = Algostream_common_utils.Time_utils.Clock

let n_points = 5000

let n_iters = 2000

(* Floors are set from measured release-profile numbers with roughly 40% headroom, not guessed.
   Measured on Apple Silicon: of_nav ~249 calls/s on a 5,000-point curve, dominated by the two
   historical-VaR sorts (see the note in Var.historical_var_es). *)
let metrics_floor = 150.0

let parse_args () =
  let json = ref None in
  let i = ref 1 in
    while !i < Array.length Sys.argv do
      (match Sys.argv.(!i) with
      | "--json" when !i + 1 < Array.length Sys.argv ->
        json := Some Sys.argv.(!i + 1) ;
        incr i
      | "--help" ->
        print_endline "Usage: metrics_throughput [--json PATH]" ;
        exit 0
      | other ->
        Printf.eprintf "unknown arg: %s\n" other ;
        exit 2) ;
      incr i
    done ;
    !json


let nav_fixture () =
  let rng = Rng.create ~seed:31 in
  let eq = ref 100_000.0 in
    Array.init n_points (fun i ->
      eq := !eq *. (1.0 +. 0.0002 +. (0.01 *. Variate.normal rng)) ;
      (Int64.mul (Int64.of_int i) 86_400_000_000_000L, !eq))


let timed n f =
  let t0 = Clock.now_monotonic_ns () in
    for _ = 1 to n do
      f ()
    done ;
    let t1 = Clock.now_monotonic_ns () in
    let elapsed = Int64.sub t1 t0 in
      (Int64.div elapsed (Int64.of_int n), float_of_int n /. (Int64.to_float elapsed /. 1e9))


let main () =
  let json_path = parse_args () in
  let nav = nav_fixture () in
  let returns = Perf.Returns.of_nav ~nav ~kind:Perf.Returns.Simple in
  let m_ns, m_ops = timed n_iters (fun () -> ignore (Perf.Metrics.of_nav ~nav ())) in
  let d_ns, d_ops = timed n_iters (fun () -> ignore (Perf.Drawdown_analysis.episodes ~nav ())) in
  let r_ns, r_ops =
    timed n_iters (fun () -> ignore (Perf.Returns.of_nav ~nav ~kind:Perf.Returns.Simple)) in
  let b_ns, b_ops =
    timed n_iters (fun () ->
      ignore
        (Perf.Benchmark_compare.compare ~strategy:returns ~benchmark:returns ~periods_per_year:252.0
           ())) in
    Printf.printf "metrics.of_nav:       points=%d ns/call=%Ld %.0f calls/s\n" n_points m_ns m_ops ;
    Printf.printf "metrics.drawdown:     points=%d ns/call=%Ld %.0f calls/s\n" n_points d_ns d_ops ;
    Printf.printf "metrics.returns:      points=%d ns/call=%Ld %.0f calls/s\n" n_points r_ns r_ops ;
    Printf.printf "metrics.benchmark:    points=%d ns/call=%Ld %.0f calls/s\n" n_points b_ns b_ops ;
    if m_ops < metrics_floor then (
      Printf.eprintf "REGRESSION: metrics %.0f calls/s is below the floor of %.0f\n" m_ops
        metrics_floor ;
      exit 1) ;
    match json_path with
    | None -> ()
    | Some path ->
      let oc = open_out path in
        Printf.fprintf oc "[\n" ;
        Printf.fprintf oc
          "  {\"name\":\"metrics.of_nav.ns_per_call\",\"unit\":\"ns\",\"value\":%Ld,\"extra\":\"%d \
           points, %.0f calls/s\"},\n"
          m_ns n_points m_ops ;
        Printf.fprintf oc
          "  \
           {\"name\":\"metrics.drawdown_episodes.ns_per_call\",\"unit\":\"ns\",\"value\":%Ld,\"extra\":\"%d \
           points\"},\n"
          d_ns n_points ;
        Printf.fprintf oc
          "  \
           {\"name\":\"metrics.benchmark_compare.ns_per_call\",\"unit\":\"ns\",\"value\":%Ld,\"extra\":\"%d \
           points\"}\n"
          b_ns n_points ;
        Printf.fprintf oc "]\n" ;
        close_out oc ;
        Printf.printf "wrote %s\n" path


let () = main ()
