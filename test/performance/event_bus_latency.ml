(** Queueing delay for [Event_bus] under saturation.

    Pushes [iters] heartbeat events through a single subscriber as fast as the producer can manage,
    measuring wall-clock time from publish to handler invocation. Emits a JSON file in
    [customSmallerIsBetter] schema for github-action-benchmark.

    {1 What this does and does not measure}

    The producer here is a tight loop with no pacing, so it outruns the single dispatcher Domain by
    an order of magnitude and the ring backs up immediately. Almost every event therefore waits
    behind a queue, and what comes out is {b backlog drain time at 100% offered load} — how the bus
    degrades when the producer wins, which is a genuinely useful thing to track.

    It is {b not} the number to compare against the project's 5 ms target. It was once published
    under the name [event_bus.publish_to_handler.*], which invited exactly that reading: the figures
    run to double-digit milliseconds and looked like a missed target. The metrics are now named for
    what they are. For latency at a stated offered load — the figure the 5 ms target is about — see
    [event_bus_paced_latency], which offers a fixed rate and reports roughly 0.15 ms at p99 on the
    same machine that produces 18 ms here.

    Note that the two series are not comparable and the rename deliberately starts a fresh history
    rather than continuing the old one under a name that meant something else. *)

module EB = Algostream_infrastructure_event_bus
module Event = EB.Event_types.Event
module Priority = EB.Event_types.Priority
module Clock = Algostream_common_utils.Time_utils.Clock
module Sleep = Algostream_common_utils.Time_utils.Sleep

let iters = 50_000

let parse_args () =
  let json = ref None in
  let i = ref 1 in
    while !i < Array.length Sys.argv do
      (match Sys.argv.(!i) with
      | "--json" when !i + 1 < Array.length Sys.argv ->
        json := Some Sys.argv.(!i + 1) ;
        incr i
      | "--help" ->
        print_endline "Usage: event_bus_latency [--json PATH]" ;
        exit 0
      | other ->
        Printf.eprintf "unknown arg: %s\n" other ;
        exit 2) ;
      incr i
    done ;
    !json


let percentile sorted p =
  let n = Array.length sorted in
    if n = 0 then 0L else sorted.(min (n - 1) ((n * p / 100) + 0))


let main () =
  let json_path = parse_args () in
  let bus = EB.Event_bus.create ~capacity_per_band:65536 () in
  let received_at = Array.make iters 0L in
  let recv_count = Atomic.make 0 in
  let _id =
    EB.Event_bus.subscribe bus (fun e ->
      let i = Int64.to_int e.sequence_id mod iters in
      let now = Clock.now_monotonic_ns () in
        received_at.(i) <- Int64.sub now e.timestamp_ns ;
        Atomic.incr recv_count) in
    EB.Event_bus.start bus ;
    let t0 = Clock.now_monotonic_ns () in
      for _ = 1 to iters do
        EB.Event_bus.publish bus (Event.create ~priority:Priority.Normal Event.Heartbeat)
      done ;
      let deadline = Int64.add (Clock.now_monotonic_ns ()) 5_000_000_000L in
        while Atomic.get recv_count < iters && Clock.now_monotonic_ns () < deadline do
          Sleep.sleep_us 100L
        done ;
        let t1 = Clock.now_monotonic_ns () in
          EB.Event_bus.stop bus ;
          let n = Atomic.get recv_count in
            if n < iters then Printf.eprintf "warning: only delivered %d/%d events\n" n iters ;

            let durations = Array.sub received_at 0 n in
              Array.sort Int64.compare durations ;
              let total = Array.fold_left Int64.add 0L durations in
              let avg = if n = 0 then 0L else Int64.div total (Int64.of_int n) in
              let min_v = if n = 0 then 0L else durations.(0) in
              let max_v = if n = 0 then 0L else durations.(n - 1) in
              let p50 = percentile durations 50 in
              let p95 = percentile durations 95 in
              let p99 = percentile durations 99 in
              let elapsed_ns = Int64.sub t1 t0 in
              let throughput =
                if Int64.compare elapsed_ns 0L = 0 then 0.0
                else Float.of_int n /. (Int64.to_float elapsed_ns /. 1_000_000_000.0) in

              Printf.printf
                "event_bus_latency: n=%d min=%Ldns avg=%Ldns p50=%Ldns p95=%Ldns p99=%Ldns \
                 max=%Ldns throughput=%.0f ev/s\n"
                n min_v avg p50 p95 p99 max_v throughput ;

              match json_path with
              | None -> ()
              | Some path ->
                let oc = open_out path in
                  Printf.fprintf oc "[\n" ;
                  Printf.fprintf oc
                    "  \
                     {\"name\":\"event_bus.saturated_queueing.avg\",\"unit\":\"ns\",\"value\":%Ld,\"extra\":\"n=%d\"},\n"
                    avg n ;
                  Printf.fprintf oc
                    "  \
                     {\"name\":\"event_bus.saturated_queueing.p50\",\"unit\":\"ns\",\"value\":%Ld,\"extra\":\"n=%d\"},\n"
                    p50 n ;
                  Printf.fprintf oc
                    "  \
                     {\"name\":\"event_bus.saturated_queueing.p95\",\"unit\":\"ns\",\"value\":%Ld,\"extra\":\"n=%d\"},\n"
                    p95 n ;
                  Printf.fprintf oc
                    "  \
                     {\"name\":\"event_bus.saturated_queueing.p99\",\"unit\":\"ns\",\"value\":%Ld,\"extra\":\"n=%d\"}\n"
                    p99 n ;
                  (* [min] is deliberately NOT published as a tracked metric.

                     The producer floods 50_000 events into the queue and the dispatcher drains
                     behind it, so almost every event waits: p50 is milliseconds. The minimum is
                     whichever single sample happened to be published at the instant the dispatcher
                     was popping — scheduling luck, not performance. Measured on gh-pages history it
                     varied 15.7x between two runs of the IDENTICAL commit, which is eight times the
                     alert threshold, so it produced nothing but false regressions. It is still
                     printed above for a human reading the run. *)
                  Printf.fprintf oc "]\n" ;
                  close_out oc ;
                  Printf.printf "wrote %s\n" path


let () = main ()
