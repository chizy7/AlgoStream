(** RNG throughput bench.

    Four hot paths:
    - [Rng.uniform] — the primitive every sampler builds on (~1-2 ns/draw expected).
    - [Rng.int_below] — Lemire multiply-shift with rejection.
    - [Variate.normal] — Box-Muller, two uniforms plus a log/sqrt/cos.
    - [Rng.substream] — per-run seeding; a Monte Carlo batch pays this once per run, so it only
      matters that it is not pathologically slow.

    Reference numbers on Apple Silicon (release profile): uniform ~2 ns, normal ~20 ns. *)

module Rng = Algostream_rng.Rng
module Variate = Algostream_stochastic.Variate
module Clock = Algostream_common_utils.Time_utils.Clock

let n_uniform = 50_000_000

let n_int = 20_000_000

let n_normal = 10_000_000

let n_substream = 1_000_000

(* Measured release-profile: uniform ~38M draws/s, normal ~13M draws/s. *)
let uniform_floor = 15_000_000.0

let normal_floor = 5_000_000.0

let parse_args () =
  let json = ref None in
  let i = ref 1 in
    while !i < Array.length Sys.argv do
      (match Sys.argv.(!i) with
      | "--json" when !i + 1 < Array.length Sys.argv ->
        json := Some Sys.argv.(!i + 1) ;
        incr i
      | "--help" ->
        print_endline "Usage: rng_throughput [--json PATH]" ;
        exit 0
      | other ->
        Printf.eprintf "unknown arg: %s\n" other ;
        exit 2) ;
      incr i
    done ;
    !json


let timed n f =
  let t0 = Clock.now_monotonic_ns () in
    f n ;
    let t1 = Clock.now_monotonic_ns () in
    let elapsed = Int64.sub t1 t0 in
    let eps = float_of_int n /. (Int64.to_float elapsed /. 1e9) in
    let nspe = Int64.div elapsed (Int64.of_int n) in
      (elapsed, nspe, eps)


let bench_uniform n =
  let r = Rng.create ~seed:1 in
  let acc = ref 0.0 in
    for _ = 1 to n do
      acc := !acc +. Rng.uniform r
    done ;
    ignore !acc


let bench_int_below n =
  let r = Rng.create ~seed:2 in
  let acc = ref 0 in
    for _ = 1 to n do
      acc := !acc + Rng.int_below r 7
    done ;
    ignore !acc


let bench_normal n =
  let r = Rng.create ~seed:3 in
  let acc = ref 0.0 in
    for _ = 1 to n do
      acc := !acc +. Variate.normal r
    done ;
    ignore !acc


let bench_substream n =
  let acc = ref 0L in
    for i = 1 to n do
      let r = Rng.substream ~root_seed:42L ~index:i in
        acc := Int64.add !acc (Rng.bits r)
    done ;
    ignore !acc


let main () =
  let json_path = parse_args () in
  let _, u_ns, u_eps = timed n_uniform bench_uniform in
  let _, i_ns, i_eps = timed n_int bench_int_below in
  let _, nm_ns, nm_eps = timed n_normal bench_normal in
  let _, s_ns, s_eps = timed n_substream bench_substream in
    Printf.printf "rng.uniform:     n=%d ns/draw=%Ld throughput=%.0f draws/s\n" n_uniform u_ns u_eps ;
    Printf.printf "rng.int_below:   n=%d ns/draw=%Ld throughput=%.0f draws/s\n" n_int i_ns i_eps ;
    Printf.printf "variate.normal:  n=%d ns/draw=%Ld throughput=%.0f draws/s\n" n_normal nm_ns
      nm_eps ;
    Printf.printf "rng.substream:   n=%d ns/draw=%Ld throughput=%.0f streams/s\n" n_substream s_ns
      s_eps ;
    if u_eps < uniform_floor then (
      Printf.eprintf "REGRESSION: uniform %.0f draws/s is below the floor of %.0f\n" u_eps
        uniform_floor ;
      exit 1) ;
    if nm_eps < normal_floor then (
      Printf.eprintf "REGRESSION: normal %.0f draws/s is below the floor of %.0f\n" nm_eps
        normal_floor ;
      exit 1) ;
    match json_path with
    | None -> ()
    | Some path ->
      let oc = open_out path in
        Printf.fprintf oc "[\n" ;
        Printf.fprintf oc
          "  \
           {\"name\":\"sto.rng_uniform.ns_per_draw\",\"unit\":\"ns\",\"value\":%Ld,\"extra\":\"throughput=%.0f \
           draws/s\"},\n"
          u_ns u_eps ;
        Printf.fprintf oc
          "  \
           {\"name\":\"sto.rng_int_below.ns_per_draw\",\"unit\":\"ns\",\"value\":%Ld,\"extra\":\"throughput=%.0f \
           draws/s\"},\n"
          i_ns i_eps ;
        Printf.fprintf oc
          "  \
           {\"name\":\"sto.variate_normal.ns_per_draw\",\"unit\":\"ns\",\"value\":%Ld,\"extra\":\"throughput=%.0f \
           draws/s\"},\n"
          nm_ns nm_eps ;
        Printf.fprintf oc
          "  \
           {\"name\":\"sto.rng_substream.ns_per_stream\",\"unit\":\"ns\",\"value\":%Ld,\"extra\":\"throughput=%.0f \
           streams/s\"}\n"
          s_ns s_eps ;
        Printf.fprintf oc "]\n" ;
        close_out oc ;
        Printf.printf "wrote %s\n" path


let () = main ()
