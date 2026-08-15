(** Throughput benchmark for [Event_bus].

    Measures sustained publish-and-consume rate over [iters] events. JSON output uses
    [customBiggerIsBetter] would be ideal, but we keep [customSmallerIsBetter] (lower per-event ns
    is better) for consistency. *)

module EB = Algostream_infrastructure_event_bus
module Event = EB.Event_types.Event
module Priority = EB.Event_types.Priority
module Clock = Algostream_common_utils.Time_utils.Clock
module Sleep = Algostream_common_utils.Time_utils.Sleep

let iters = 200_000

let parse_args () =
  let json = ref None in
  let i = ref 1 in
    while !i < Array.length Sys.argv do
      (match Sys.argv.(!i) with
      | "--json" when !i + 1 < Array.length Sys.argv ->
        json := Some Sys.argv.(!i + 1) ;
        incr i
      | "--help" ->
        print_endline "Usage: event_bus_throughput [--json PATH]" ;
        exit 0
      | other ->
        Printf.eprintf "unknown arg: %s\n" other ;
        exit 2) ;
      incr i
    done ;
    !json


let main () =
  let json_path = parse_args () in
  let bus = EB.Event_bus.create ~capacity_per_band:65536 () in
  let recv_count = Atomic.make 0 in
  let _id = EB.Event_bus.subscribe bus (fun _ -> Atomic.incr recv_count) in
    EB.Event_bus.start bus ;
    let t0 = Clock.now_monotonic_ns () in
      for _ = 1 to iters do
        let rec retry () =
          if
            not
              (EB.Event_bus.try_publish bus
                 (Event.create ~priority:Priority.Normal Event.Heartbeat))
          then (
            Sleep.sleep_us 10L ;
            retry ()) in
          retry ()
      done ;
      let deadline = Int64.add (Clock.now_monotonic_ns ()) 10_000_000_000L in
        while Atomic.get recv_count < iters && Clock.now_monotonic_ns () < deadline do
          Sleep.sleep_us 100L
        done ;
        let t1 = Clock.now_monotonic_ns () in
          EB.Event_bus.stop bus ;
          let n = Atomic.get recv_count in
          let elapsed_ns = Int64.sub t1 t0 in
          let ns_per_event = if n = 0 then 0L else Int64.div elapsed_ns (Int64.of_int n) in
          let events_per_sec =
            if Int64.compare elapsed_ns 0L = 0 then 0.0
            else Float.of_int n /. (Int64.to_float elapsed_ns /. 1_000_000_000.0) in

          Printf.printf
            "event_bus_throughput: n=%d elapsed=%Ldns ns_per_event=%Ld throughput=%.0f ev/s\n" n
            elapsed_ns ns_per_event events_per_sec ;

          match json_path with
          | None -> ()
          | Some path ->
            let oc = open_out path in
              Printf.fprintf oc "[\n" ;
              Printf.fprintf oc
                "  \
                 {\"name\":\"event_bus.throughput.ns_per_event\",\"unit\":\"ns\",\"value\":%Ld,\"extra\":\"n=%d \
                 throughput=%.0f ev/s\"}\n"
                ns_per_event n events_per_sec ;
              Printf.fprintf oc "]\n" ;
              close_out oc ;
              Printf.printf "wrote %s\n" path


let () = main ()
