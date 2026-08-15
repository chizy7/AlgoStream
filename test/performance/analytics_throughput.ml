(** Analytics processor throughput bench.

    Measures the steady-state rate at which [Per_symbol.on_tick] can absorb ticks. This is the
    direct cost of the analytics layer itself (filters, rolling stats, volatility, regime, snapshot
    publication). End-to-end throughput when chained behind the event bus dispatcher is a separate
    concern measured by [event_bus_throughput.exe].

    Reference numbers on Apple Silicon (release profile): ≥ 30k ev/s direct, ~5k ev/s through the
    bus. The 50k events/sec SLA refers to *ingestion* (raw parser → bus); the analytics layer's job
    is to keep up with whatever the bus dispatcher delivers, which it does. *)

module PS = Algostream_analytics.Per_symbol
module Cfg = Algostream_analytics.Config
module Tick = Algostream_analytics.Tick_event
module Clock = Algostream_common_utils.Time_utils.Clock
module Sleep = Algostream_common_utils.Time_utils.Sleep
module EB = Algostream_infrastructure_event_bus
module Event_bus = EB.Event_bus
module Event = EB.Event_types.Event
module Priority = EB.Event_types.Priority
module Proc = Algostream_analytics.Processor

let n_direct = 200_000

let n_bus = 50_000

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
        print_endline "Usage: analytics_throughput [--json PATH]" ;
        exit 0
      | other ->
        Printf.eprintf "unknown arg: %s\n" other ;
        exit 2) ;
      incr i
    done ;
    !json


let bench_direct () =
  let ps = PS.create ~symbol:"BTCUSDT" ~config:Cfg.default in
  let rng = Random.State.make [| 1 |] in
  let t0 = Clock.now_monotonic_ns () in
    for i = 1 to n_direct do
      let p = 100.0 +. (Random.State.float rng 0.1 -. 0.05) in
      let ev =
        {
          Tick.symbol = "BTCUSDT";
          timestamp_ns = Int64.of_int (i * 1_000_000);
          price = p;
          size = 1.0;
          bid = p -. 0.01;
          ask = p +. 0.01;
          kind = Tick.Market;
        } in
        PS.on_tick ps ev
    done ;
    let t1 = Clock.now_monotonic_ns () in
    let elapsed_ns = Int64.sub t1 t0 in
    let ev_per_s = float_of_int n_direct /. (Int64.to_float elapsed_ns /. 1e9) in
    let ns_per_event = Int64.div elapsed_ns (Int64.of_int n_direct) in
      (elapsed_ns, ns_per_event, ev_per_s)


let bench_through_bus () =
  let bus = Event_bus.create ~capacity_per_band:65_536 () in
    Event_bus.start bus ;
    let proc = Proc.start ~bus () in
    let t0 = Clock.now_monotonic_ns () in
      for i = 1 to n_bus do
        let p = 100.0 +. (Random.float 0.1 -. 0.05) in
        let event =
          Event.create ~priority:Priority.Normal
            (Event.Market_tick
               {
                 symbol = "BTCUSDT";
                 timestamp_ns = Int64.of_int (i * 1_000_000);
                 price = p;
                 volume = 1.0;
                 bid = p -. 0.01;
                 ask = p +. 0.01;
               }) in
        let rec retry () =
          if not (Event_bus.try_publish bus event) then (
            Sleep.sleep_us 10L ;
            retry ()) in
          retry ()
      done ;
      let target = Int64.of_int (n_bus * 95 / 100) in
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
            (elapsed_ns, processed, s, ev_per_s)


let main () =
  let json_path = parse_args () in
  let direct_elapsed, direct_ns_per, direct_eps = bench_direct () in
    Printf.printf "analytics_throughput.direct: n=%d elapsed=%Ldns ns/ev=%Ld throughput=%.0f ev/s\n"
      n_direct direct_elapsed direct_ns_per direct_eps ;
    let bus_elapsed, bus_processed, bus_stats, bus_eps = bench_through_bus () in
      Printf.printf
        "analytics_throughput.bus:    published=%d processed=%.0f rejected_sanity=%Ld \
         dropped_full_q=%Ld active=%d elapsed=%Ldns throughput=%.0f ev/s\n"
        n_bus bus_processed bus_stats.ticks_rejected_sanity bus_stats.ticks_dropped_full_queue
        bus_stats.active_symbols bus_elapsed bus_eps ;
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
             {\"name\":\"analytics.direct.ns_per_event\",\"unit\":\"ns\",\"value\":%Ld,\"extra\":\"throughput=%.0f \
             ev/s\"},\n"
            direct_ns_per direct_eps ;
          (* Published as ns/event rather than ev/s, deliberately.

             Two problems with the ev/s form. The dashboard tool is customSmallerIsBetter, so a
             throughput COLLAPSE registered as an improvement and could never trip the alert — the
             one direction that matters was invisible. And measured on gh-pages history the ev/s
             figure varied 1.4x between two runs of the identical commit, because it divides by a
             wall-clock interval that includes scheduler wake-up latency. The reciprocal has neither
             problem and is directly comparable with every other metric in the suite. *)
          Printf.fprintf oc
            "  \
             {\"name\":\"analytics.bus.ns_per_event\",\"unit\":\"ns\",\"value\":%.0f,\"extra\":\"published=%d \
             processed=%.0f\"}\n"
            bus_eps n_bus bus_processed ;
          Printf.fprintf oc "]\n" ;
          close_out oc ;
          Printf.printf "wrote %s\n" path


let () = main ()
