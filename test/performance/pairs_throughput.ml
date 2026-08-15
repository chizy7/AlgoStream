(** Pairs processor throughput bench.

    Measures the steady-state rate at which [Per_pair.on_tick] can absorb paired-leg ticks. The
    direct path exercises the tick-cadence hot loop: hedge-ratio update, rolling correlation, spread
    \+ z-score, mean-reversion classifier, snapshot publication. The bus path adds the bus
    dispatcher + SPSC enqueue / dequeue cost.

    Reference numbers on Apple Silicon (release profile): ≥ 30k ev/s direct, ~3-5k ev/s through the
    bus. Bus is lower than the analytics bench because pairs fans each tick out to every pair
    containing the symbol; with a single pair the overhead is the SPSC handoff. *)

module PP = Algostream_pairs.Per_pair
module Cfg = Algostream_pairs.Config
module Proc = Algostream_pairs.Processor
module Pair_id = Algostream_pairs.Pair_id
module Symbol = Algostream_normalization.Symbol
module Clock = Algostream_common_utils.Time_utils.Clock
module Sleep = Algostream_common_utils.Time_utils.Sleep
module EB = Algostream_infrastructure_event_bus
module Event_bus = EB.Event_bus
module Event = EB.Event_types.Event
module Priority = EB.Event_types.Priority

let n_direct = 200_000

let n_bus_per_symbol = 50_000

let regression_floor_ev_s = 20_000.0

let parse_args () =
  let json = ref None in
  let i = ref 1 in
    while !i < Array.length Sys.argv do
      (match Sys.argv.(!i) with
      | "--json" when !i + 1 < Array.length Sys.argv ->
        json := Some Sys.argv.(!i + 1) ;
        incr i
      | "--help" ->
        print_endline "Usage: pairs_throughput [--json PATH]" ;
        exit 0
      | other ->
        Printf.eprintf "unknown arg: %s\n" other ;
        exit 2) ;
      incr i
    done ;
    !json


let make_pair () =
  let sy = { Symbol.base = "BTC"; quote = "USDT"; asset_class = Symbol.Crypto } in
  let sx = { Symbol.base = "ETH"; quote = "USDT"; asset_class = Symbol.Crypto } in
    Pair_id.of_symbols sy sx


let bench_direct () =
  let pid = make_pair () in
  let pp = PP.create ~pair:pid ~config:Cfg.default in
  let rng = Random.State.make [| 1 |] in
  let t0 = Clock.now_monotonic_ns () in
    for i = 1 to n_direct do
      let x = 2000.0 +. (Random.State.float rng 1.0 -. 0.5) in
      let y = (2.0 *. x) +. (Random.State.float rng 1.0 -. 0.5) in
        PP.on_tick pp ~y_price:y ~x_price:x ~ts_ns:(Int64.of_int (i * 1_000_000))
    done ;
    let t1 = Clock.now_monotonic_ns () in
    let elapsed_ns = Int64.sub t1 t0 in
    let ev_per_s = float_of_int n_direct /. (Int64.to_float elapsed_ns /. 1e9) in
    let ns_per_event = Int64.div elapsed_ns (Int64.of_int n_direct) in
      (elapsed_ns, ns_per_event, ev_per_s)


let bench_through_bus () =
  let bus = Event_bus.create ~capacity_per_band:65_536 () in
    Event_bus.start bus ;
    let pid = make_pair () in
    let proc =
      Proc.start ~bus ~pairs:[ { Proc.pair = pid; y_raw = "BTCUSDT"; x_raw = "ETHUSDT" } ] () in
    let total = n_bus_per_symbol * 2 in
    let t0 = Clock.now_monotonic_ns () in
      for i = 1 to n_bus_per_symbol do
        let ts = Int64.of_int (i * 1_000_000) in
        let px_y = 30_000.0 +. (Random.float 0.5 -. 0.25) in
        let px_x = 2_000.0 +. (Random.float 0.5 -. 0.25) in
        let ev_y =
          Event.create ~priority:Priority.Normal
            (Event.Market_tick
               {
                 symbol = "BTCUSDT";
                 timestamp_ns = ts;
                 price = px_y;
                 volume = 1.0;
                 bid = px_y -. 0.05;
                 ask = px_y +. 0.05;
               }) in
        let ev_x =
          Event.create ~priority:Priority.Normal
            (Event.Market_tick
               {
                 symbol = "ETHUSDT";
                 timestamp_ns = ts;
                 price = px_x;
                 volume = 1.0;
                 bid = px_x -. 0.01;
                 ask = px_x +. 0.01;
               }) in
        let rec retry e =
          if not (Event_bus.try_publish bus e) then (
            Sleep.sleep_us 10L ;
            retry e) in
          retry ev_y ;
          retry ev_x
      done ;
      let target = Int64.of_int (total * 90 / 100) in
      let deadline = Int64.add (Clock.now_monotonic_ns ()) 30_000_000_000L in
        while
          Int64.compare (Proc.stats proc).ticks_processed target < 0
          && Clock.now_monotonic_ns () < deadline
        do
          Sleep.sleep_us 200L
        done ;
        let t1 = Clock.now_monotonic_ns () in
        let s = Proc.stats proc in
          Proc.stop proc ;
          Event_bus.stop bus ;
          let elapsed_ns = Int64.sub t1 t0 in
          let processed = Int64.to_float s.ticks_processed in
          let ev_per_s =
            if Int64.compare elapsed_ns 0L > 0 then processed /. (Int64.to_float elapsed_ns /. 1e9)
            else 0.0 in
            (elapsed_ns, processed, s, ev_per_s, total)


let main () =
  let json_path = parse_args () in
  let direct_elapsed, direct_ns_per, direct_eps = bench_direct () in
    Printf.printf "pairs_throughput.direct: n=%d elapsed=%Ldns ns/ev=%Ld throughput=%.0f ev/s\n"
      n_direct direct_elapsed direct_ns_per direct_eps ;
    let bus_elapsed, bus_processed, bus_stats, bus_eps, total = bench_through_bus () in
      Printf.printf
        "pairs_throughput.bus:    published=%d processed=%.0f dropped_full_q=%Ld active=%d \
         elapsed=%Ldns throughput=%.0f ev/s\n"
        total bus_processed bus_stats.ticks_dropped_full_queue bus_stats.active_pairs bus_elapsed
        bus_eps ;
      if direct_eps < regression_floor_ev_s then (
        Printf.eprintf
          "REGRESSION: direct throughput %.0f ev/s is below the regression floor of %.0f ev/s\n"
          direct_eps regression_floor_ev_s ;
        exit 1) ;
      match json_path with
      | None -> ()
      | Some path ->
        let oc = open_out path in
          Printf.fprintf oc "[\n" ;
          Printf.fprintf oc
            "  \
             {\"name\":\"pairs.direct.ns_per_event\",\"unit\":\"ns\",\"value\":%Ld,\"extra\":\"throughput=%.0f \
             ev/s\"},\n"
            direct_ns_per direct_eps ;
          (* Published as ns/event rather than ev/s, deliberately.

             Two problems with the ev/s form. The dashboard tool is customSmallerIsBetter, so a
             throughput COLLAPSE registered as an improvement and could never trip the alert — the
             one direction that matters was invisible. And measured on gh-pages history the ev/s
             figure varied 114x between two runs of the identical commit, because it divides by a
             wall-clock interval that includes scheduler wake-up latency. The reciprocal has neither
             problem and is directly comparable with every other metric in the suite. *)
          Printf.fprintf oc
            "  \
             {\"name\":\"pairs.bus.ns_per_event\",\"unit\":\"ns\",\"value\":%.0f,\"extra\":\"published=%d \
             processed=%.0f\"}\n"
            (if bus_eps > 0.0 then 1e9 /. bus_eps else 0.0)
            total bus_processed ;
          Printf.fprintf oc "]\n" ;
          close_out oc ;
          Printf.printf "wrote %s\n" path


let () = main ()
