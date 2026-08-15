(** Advanced statistical models throughput bench.

    Three hot paths:
    - [Kalman_hedge.update] — bivariate Kalman per-observation cost (~12 multiply-adds + 2×2 matrix
      ops).
    - [Garch11.update] — single multiply-add chain for online variance forecast.
    - [Pca.fit] on a 32-feature, 500-sample dataset — Jacobi eigendecomposition cost.

    Reference numbers on Apple Silicon (release profile): ≥ 5M updates/sec for both online paths;
    PCA fit < 50 ms. *)

module KH = Algostream_advanced_models.Kalman_hedge
module G = Algostream_advanced_models.Garch11
module Pca = Algostream_advanced_models.Pca
module Clock = Algostream_common_utils.Time_utils.Clock

let n_kalman = 1_000_000

let n_garch = 1_000_000

let pca_features = 32

let pca_samples = 500

let kalman_floor_ev_s = 500_000.0

let garch_floor_ev_s = 500_000.0

let pca_ceiling_ms = 500.0

let parse_args () =
  let json = ref None in
  let i = ref 1 in
    while !i < Array.length Sys.argv do
      (match Sys.argv.(!i) with
      | "--json" when !i + 1 < Array.length Sys.argv ->
        json := Some Sys.argv.(!i + 1) ;
        incr i
      | "--help" ->
        print_endline "Usage: advanced_models_throughput [--json PATH]" ;
        exit 0
      | other ->
        Printf.eprintf "unknown arg: %s\n" other ;
        exit 2) ;
      incr i
    done ;
    !json


let bench_kalman () =
  let kf = KH.create () in
  let rng = Random.State.make [| 11 |] in
  let xs = Array.init n_kalman (fun _ -> Random.State.float rng 2.0 -. 1.0) in
  let ys = Array.init n_kalman (fun i -> 2.0 *. xs.(i)) in
  let t0 = Clock.now_monotonic_ns () in
    for i = 0 to n_kalman - 1 do
      let _ = KH.update kf ~y:ys.(i) ~x:xs.(i) in
        ()
    done ;
    let t1 = Clock.now_monotonic_ns () in
    let elapsed_ns = Int64.sub t1 t0 in
    let ev_s = float_of_int n_kalman /. (Int64.to_float elapsed_ns /. 1e9) in
    let ns_per = Int64.div elapsed_ns (Int64.of_int n_kalman) in
      (elapsed_ns, ns_per, ev_s)


let bench_garch () =
  (* Pre-fit a small returns series, then time update() *)
  let rng = Random.State.make [| 12 |] in
  let returns_init = Array.init 500 (fun _ -> (0.01 *. Random.State.float rng 2.0) -. 0.01) in
    match G.fit ~returns:returns_init () with
    | Error _ ->
      Printf.eprintf "GARCH fit failed during bench setup\n" ;
      exit 1
    | Ok fit_res ->
      let online =
        G.of_fit fit_res ~last_return:returns_init.(499) ~last_variance:fit_res.long_run_variance
      in
      let rs = Array.init n_garch (fun _ -> 0.01 *. (Random.State.float rng 2.0 -. 1.0)) in
      let t0 = Clock.now_monotonic_ns () in
        for i = 0 to n_garch - 1 do
          let _ = G.update online ~r:rs.(i) in
            ()
        done ;
        let t1 = Clock.now_monotonic_ns () in
        let elapsed_ns = Int64.sub t1 t0 in
        let ev_s = float_of_int n_garch /. (Int64.to_float elapsed_ns /. 1e9) in
        let ns_per = Int64.div elapsed_ns (Int64.of_int n_garch) in
          (elapsed_ns, ns_per, ev_s)


let bench_pca () =
  let rng = Random.State.make [| 13 |] in
  let data =
    Array.init pca_samples (fun _ ->
      Array.init pca_features (fun _ -> Random.State.float rng 2.0 -. 1.0)) in
  let t0 = Clock.now_monotonic_ns () in
  let _pca = Pca.fit ~data () in
  let t1 = Clock.now_monotonic_ns () in
  let elapsed_ns = Int64.sub t1 t0 in
  let elapsed_ms = Int64.to_float elapsed_ns /. 1e6 in
    (elapsed_ns, elapsed_ms)


let main () =
  let json_path = parse_args () in
  let k_elapsed, k_ns_per, k_eps = bench_kalman () in
    Printf.printf "kalman_hedge.update: n=%d elapsed=%Ldns ns/ev=%Ld throughput=%.0f ev/s\n"
      n_kalman k_elapsed k_ns_per k_eps ;
    let g_elapsed, g_ns_per, g_eps = bench_garch () in
      Printf.printf "garch11.update:      n=%d elapsed=%Ldns ns/ev=%Ld throughput=%.0f ev/s\n"
        n_garch g_elapsed g_ns_per g_eps ;
      let pca_elapsed, pca_ms = bench_pca () in
        Printf.printf "pca.fit:             samples=%d features=%d elapsed=%Ldns (%.2fms)\n"
          pca_samples pca_features pca_elapsed pca_ms ;
        if k_eps < kalman_floor_ev_s then (
          Printf.eprintf "REGRESSION: kalman_hedge %.0f ev/s below floor %.0f\n" k_eps
            kalman_floor_ev_s ;
          exit 1) ;
        if g_eps < garch_floor_ev_s then (
          Printf.eprintf "REGRESSION: garch11 %.0f ev/s below floor %.0f\n" g_eps garch_floor_ev_s ;
          exit 1) ;
        if pca_ms > pca_ceiling_ms then (
          Printf.eprintf "REGRESSION: pca.fit %.2fms above ceiling %.2fms\n" pca_ms pca_ceiling_ms ;
          exit 1) ;
        match json_path with
        | None -> ()
        | Some path ->
          let oc = open_out path in
            Printf.fprintf oc "[\n" ;
            Printf.fprintf oc
              "  \
               {\"name\":\"adv.kalman_hedge.ns_per_event\",\"unit\":\"ns\",\"value\":%Ld,\"extra\":\"throughput=%.0f \
               ev/s\"},\n"
              k_ns_per k_eps ;
            Printf.fprintf oc
              "  \
               {\"name\":\"adv.garch11.ns_per_event\",\"unit\":\"ns\",\"value\":%Ld,\"extra\":\"throughput=%.0f \
               ev/s\"},\n"
              g_ns_per g_eps ;
            Printf.fprintf oc
              "  \
               {\"name\":\"adv.pca.fit_ms\",\"unit\":\"ms\",\"value\":%.2f,\"extra\":\"features=%d \
               samples=%d\"}\n"
              pca_ms pca_features pca_samples ;
            Printf.fprintf oc "]\n" ;
            close_out oc ;
            Printf.printf "wrote %s\n" path


let () = main ()
