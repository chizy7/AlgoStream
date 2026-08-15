(** Open-loop latency for [Event_bus] at a stated offered load.

    {1 Why this exists alongside [event_bus_latency]}

    The headline design target is a sub-5 ms execution path. The existing latency benchmark
    publishes 50,000 events in a tight loop with no pacing, so the producer outruns the single
    dispatcher Domain by a wide margin, the ring backs up, and what it reports is
    {b queueing delay at 100% offered load} — the time an event spends waiting behind the backlog,
    not the time the system takes to handle it. On CI that reads as ~7.4 ms average and ~12.5 ms
    p99, which looks like a 5 ms target being missed by 2.5x. It is not measuring the thing the
    target is about.

    This benchmark offers a {i fixed rate} instead — 50,000 events/second by default, which is the
    throughput figure the SLA itself states — and reports the latency distribution under that load.
    That number is comparable to the 5 ms target. The saturation benchmark keeps its job: telling
    you what happens when the producer wins.

    {1 Coordinated omission}

    The trap in any paced benchmark is measuring from when you {i managed} to publish rather than
    from when you {i intended} to. If the system stalls, a naive publisher stalls with it, publishes
    late, and records a short latency for an event that was actually delayed — the stall vanishes
    from the results precisely when it matters most.

    So each event carries its {b scheduled} time in [timestamp_ns] rather than the time it was
    really handed to the bus. [Event.t] is a public record, so this is a direct construction rather
    than [Event.create]. The handler's [now - timestamp_ns] then includes any time the publisher
    itself spent behind schedule, and a stall shows up at full size. [behind_schedule] reports how
    much of that happened, so a run where the publisher could not keep up is visible rather than
    silently folded into the latency figures. *)

module EB = Algostream_infrastructure_event_bus
module Event = EB.Event_types.Event
module Priority = EB.Event_types.Priority
module Clock = Algostream_common_utils.Time_utils.Clock

let default_rate = 50_000

let default_seconds = 4

let parse_args () =
  let json = ref None in
  let rate = ref default_rate in
  let seconds = ref default_seconds in
  let i = ref 1 in
    while !i < Array.length Sys.argv do
      (match Sys.argv.(!i) with
      | "--json" when !i + 1 < Array.length Sys.argv ->
        json := Some Sys.argv.(!i + 1) ;
        incr i
      | "--rate" when !i + 1 < Array.length Sys.argv ->
        rate := int_of_string Sys.argv.(!i + 1) ;
        incr i
      | "--seconds" when !i + 1 < Array.length Sys.argv ->
        seconds := int_of_string Sys.argv.(!i + 1) ;
        incr i
      | "--help" ->
        print_endline "Usage: event_bus_paced_latency [--rate N] [--seconds N] [--json PATH]" ;
        exit 0
      | other ->
        Printf.eprintf "unknown arg: %s\n" other ;
        exit 2) ;
      incr i
    done ;
    (!json, !rate, !seconds)


(* Nearest-rank percentile over a sorted array. *)
let percentile sorted p =
  let n = Array.length sorted in
    if n = 0 then 0 else sorted.(min (n - 1) (n * p / 100))


(* Spin until [target]. At 50k ev/s the gap is 20 us, which is below the resolution any sleep
   syscall can hold to — a sleep here would itself become the thing being measured. Burning a core
   is the right trade for a benchmark that exists to measure microseconds. *)
let spin_until target =
  while Int64.compare (Clock.now_monotonic_ns ()) target < 0 do
    Domain.cpu_relax ()
  done


let main () =
  let json_path, rate, seconds = parse_args () in
  let iters = rate * seconds in
  let interval_ns = Int64.of_float (1e9 /. float_of_int rate) in

  let bus = EB.Event_bus.create ~capacity_per_band:65536 () in
  (* [int], not [int64]. An [int64 array] is an array of pointers, so every write in the handler
     allocates a fresh box — 200k boxes on the dispatcher Domain, and OCaml 5's minor collections
     are stop-the-world across Domains, so that allocation stalls the *publisher* as well and lands
     in the very numbers being measured. A latency in nanoseconds fits an OCaml [int] with 40-odd
     bits to spare. Indexed by arrival order, not sequence id: the handler is the only writer, so a
     counter is exact and needs no modular mapping that could alias. *)
  let latencies = Array.make iters 0 in
  let recv_count = Atomic.make 0 in

  let _id =
    EB.Event_bus.subscribe bus (fun (e : Event.t) ->
      let now = Clock.now_monotonic_ns () in
      let i = Atomic.fetch_and_add recv_count 1 in
        if i < iters then latencies.(i) <- Int64.to_int (Int64.sub now e.timestamp_ns)) in

  EB.Event_bus.start bus ;

  let t0 = Clock.now_monotonic_ns () in
  (* How far behind the schedule the publisher fell, summed. Non-zero means the offered rate was
     more than this machine could actually offer, and the latency numbers below are measuring that
     as much as the bus. *)
  let behind_total = ref 0L in
  let behind_max = ref 0L in

  for i = 0 to iters - 1 do
    let scheduled = Int64.add t0 (Int64.mul (Int64.of_int i) interval_ns) in
    let before = Clock.now_monotonic_ns () in
      (if Int64.compare before scheduled < 0 then spin_until scheduled
       else
         let late = Int64.sub before scheduled in
           behind_total := Int64.add !behind_total late ;
           if Int64.compare late !behind_max > 0 then behind_max := late) ;
      (* [timestamp_ns] is the scheduled time, not [now] — see the coordinated-omission note. *)
      EB.Event_bus.publish bus
        {
          Event.sequence_id = Event.next_sequence_id ();
          timestamp_ns = scheduled;
          priority = Priority.Normal;
          source = "paced_bench";
          payload = Event.Heartbeat;
        }
  done ;

  let deadline = Int64.add (Clock.now_monotonic_ns ()) 5_000_000_000L in
    while Atomic.get recv_count < iters && Int64.compare (Clock.now_monotonic_ns ()) deadline < 0 do
      Domain.cpu_relax ()
    done ;
    EB.Event_bus.stop bus ;

    let n = min (Atomic.get recv_count) iters in
      if n < iters then Printf.eprintf "warning: only delivered %d/%d events\n" n iters ;

      let durations = Array.sub latencies 0 n in
        Array.sort compare durations ;
        let total = Array.fold_left ( + ) 0 durations in
        let avg = if n = 0 then 0 else total / n in
        let p50 = percentile durations 50 in
        let p95 = percentile durations 95 in
        let p99 = percentile durations 99 in
        let max_v = if n = 0 then 0 else durations.(n - 1) in
        let behind_avg = if iters = 0 then 0L else Int64.div !behind_total (Int64.of_int iters) in

        Printf.printf
          "event_bus_paced_latency: rate=%d/s n=%d avg=%dns p50=%dns p95=%dns p99=%dns max=%dns \
           behind_avg=%Ldns behind_max=%Ldns\n"
          rate n avg p50 p95 p99 max_v behind_avg !behind_max ;
        (* Judge the publisher on the *average* shortfall, not the worst one. A single GC pause puts
           [behind_max] in the milliseconds on an otherwise perfectly paced run, so keying the
           warning off the maximum cries wolf every time. Systematically failing to keep pace shows
           up as [behind_avg] approaching the inter-event interval; anything well under that is the
           publisher catching back up, which is what the schedule is for. *)
        if Int64.compare behind_avg (Int64.div interval_ns 2L) > 0 then
          Printf.eprintf
            "warning: publisher averaged %Ld ns behind a %Ld ns schedule — this machine could not \
             sustain %d ev/s, so the figures above include the shortfall rather than measuring the \
             bus\n"
            behind_avg interval_ns rate ;

        match json_path with
        | None -> ()
        | Some path ->
          let oc = open_out path in
          let extra = Printf.sprintf "rate=%d n=%d" rate n in
            Printf.fprintf oc "[\n" ;
            List.iteri
              (fun idx (name, value) ->
                Printf.fprintf oc
                  "  {\"name\":\"%s\",\"unit\":\"ns\",\"value\":%d,\"extra\":\"%s\"}%s\n" name value
                  extra
                  (if idx = 3 then "" else ","))
              [
                ("event_bus.paced.avg", avg);
                ("event_bus.paced.p50", p50);
                ("event_bus.paced.p95", p95);
                ("event_bus.paced.p99", p99);
              ] ;
            Printf.fprintf oc "]\n" ;
            close_out oc ;
            Printf.printf "wrote %s\n" path


let () = main ()
