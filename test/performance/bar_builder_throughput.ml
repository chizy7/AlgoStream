(** Bar builder throughput bench.

    Measures the rate at which a single [Bar_builder.t] can absorb ticks. Direct call (no bus, no
    Domain), so this is the intrinsic per-tick cost of the aggregator. JSON output for
    github-action-benchmark. *)

module BB = Algostream_time_series.Bar_builder
module Clock = Algostream_common_utils.Time_utils.Clock

let n_ticks = 1_000_000

let regression_floor_ev_s = 200_000.0

let parse_args () =
  let json = ref None in
  let i = ref 1 in
    while !i < Array.length Sys.argv do
      (match Sys.argv.(!i) with
      | "--json" when !i + 1 < Array.length Sys.argv ->
        json := Some Sys.argv.(!i + 1) ;
        incr i
      | "--help" ->
        print_endline "Usage: bar_builder_throughput [--json PATH]" ;
        exit 0
      | other ->
        Printf.eprintf "unknown arg: %s\n" other ;
        exit 2) ;
      incr i
    done ;
    !json


let main () =
  let json_path = parse_args () in
  let bb = BB.create ~symbol:"BTCUSDT" ~interval_ns:1_000_000_000L in
  let rng = Random.State.make [| 1 |] in
  let bars_emitted = ref 0 in
  let t0 = Clock.now_monotonic_ns () in
    for i = 1 to n_ticks do
      let p = 100.0 +. (Random.State.float rng 0.1 -. 0.05) in
      (* 1 ms apart so we cross a 1s bar boundary every 1000 ticks → ~1000 bars in this run *)
      let ts = Int64.of_int (i * 1_000_000) in
        match BB.on_tick bb ~ts ~price:p ~size:1.0 with None -> () | Some _ -> incr bars_emitted
    done ;
    let t1 = Clock.now_monotonic_ns () in
    let elapsed_ns = Int64.sub t1 t0 in
    let ev_per_s = float_of_int n_ticks /. (Int64.to_float elapsed_ns /. 1e9) in
    let ns_per_event = Int64.div elapsed_ns (Int64.of_int n_ticks) in
      Printf.printf
        "bar_builder_throughput: ticks=%d elapsed=%Ldns ns/tick=%Ld throughput=%.0f tick/s bars=%d\n"
        n_ticks elapsed_ns ns_per_event ev_per_s !bars_emitted ;
      if ev_per_s < regression_floor_ev_s then (
        Printf.eprintf
          "REGRESSION: throughput %.0f tick/s is below the regression floor of %.0f tick/s\n"
          ev_per_s regression_floor_ev_s ;
        exit 1) ;
      match json_path with
      | None -> ()
      | Some path ->
        let oc = open_out path in
          Printf.fprintf oc "[\n" ;
          Printf.fprintf oc
            "  \
             {\"name\":\"time_series.bar_builder.ns_per_tick\",\"unit\":\"ns\",\"value\":%Ld,\"extra\":\"throughput=%.0f \
             tick/s bars=%d\"}\n"
            ns_per_event ev_per_s !bars_emitted ;
          Printf.fprintf oc "]\n" ;
          close_out oc ;
          Printf.printf "wrote %s\n" path


let () = main ()
