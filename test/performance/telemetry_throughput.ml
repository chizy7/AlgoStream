(* Cost of observability.

   The collector's bus handler runs inline on the dispatcher Domain for every event, so every other
   subscriber pays for it. This measures what that costs, and what the histogram costs on its own.

   Reported as ns/op because the benchmark dashboard is customSmallerIsBetter. *)

module H = Algostream_telemetry.Histogram
module Collector = Algostream_telemetry.Collector
module EB = Algostream_infrastructure_event_bus
module Event_bus = EB.Event_bus
module Event = EB.Event_types.Event
module Priority = EB.Event_types.Priority
module Clock = Algostream_common_utils.Time_utils.Clock

let iterations = 2_000_000

let bench name f =
  (* Warm up so the first measured iteration is not paying for lazy initialisation. *)
  for _ = 1 to 100_000 do
    f ()
  done ;
  let t0 = Clock.now_monotonic_ns () in
    for _ = 1 to iterations do
      f ()
    done ;
    let t1 = Clock.now_monotonic_ns () in
    let ns = Int64.to_float (Int64.sub t1 t0) /. float_of_int iterations in
      Printf.printf "  %-38s %8.1f ns/op\n%!" name ns ;
      (name, ns)


let () =
  let json = ref None in
  let i = ref 1 in
    while !i < Array.length Sys.argv do
      if String.equal Sys.argv.(!i) "--json" && !i + 1 < Array.length Sys.argv then (
        json := Some Sys.argv.(!i + 1) ;
        incr i) ;
      incr i
    done ;

    print_endline "telemetry throughput" ;

    let h = H.create () in
    let x = ref 0 in
    let r_record =
      bench "histogram.record" (fun () ->
        incr x ;
        H.record h (Int64.of_int (!x land 0xFFFF))) in
    let r_pct = bench "histogram.percentile" (fun () -> ignore (H.percentile h 99.0 : int64)) in

    (* Full path: publish through a live bus with the collector attached. Measures the marginal cost
       the collector adds to a bus that is already running. *)
    let bus = Event_bus.create () in
      Event_bus.start bus ;
      let c = Collector.create ~bus () in
        Collector.start c ;
        let ev () =
          Event.create ~priority:Priority.Normal
            (Event.Market_tick
               {
                 symbol = "BTCUSDT";
                 timestamp_ns = Clock.now_monotonic_ns ();
                 price = 100.0;
                 volume = 1.0;
                 bid = 99.0;
                 ask = 101.0;
               }) in
        let r_pub = bench "bus.publish_with_collector" (fun () -> Event_bus.publish bus (ev ())) in
        let r_snap = bench "collector.snapshot" (fun () -> ignore (Collector.snapshot c)) in
          Collector.stop c ;
          Event_bus.stop bus ;

          match !json with
          | None -> ()
          | Some path ->
            let oc = open_out path in
            let rows = [ r_record; r_pct; r_pub; r_snap ] in
              output_string oc "[\n" ;
              List.iteri
                (fun i (name, ns) ->
                  Printf.fprintf oc
                    "  \
                     {\"name\":\"telemetry.%s\",\"unit\":\"ns\",\"value\":%.0f,\"extra\":\"iter=%d\"}%s\n"
                    name ns iterations
                    (if i = List.length rows - 1 then "" else ","))
                rows ;
              output_string oc "]\n" ;
              close_out oc ;
              Printf.printf "wrote %s\n" path
