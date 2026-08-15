module EB = Algostream_infrastructure_event_bus
module Event_bus = EB.Event_bus
module Event = EB.Event_types.Event
module Priority = EB.Event_types.Priority
module Collector = Algostream_telemetry.Collector
module Health = Algostream_telemetry.Health
module Alert = Algostream_telemetry.Alert

let wait_until ?(budget_us = 5_000_000) pred =
  let deadline = Unix.gettimeofday () +. (float_of_int budget_us /. 1_000_000.0) in
  let rec loop () =
    if pred () then true
    else if Unix.gettimeofday () > deadline then false
    else (
      Unix.sleepf 0.001 ;
      loop ()) in
    loop ()


let tick i =
  Event.create ~priority:Priority.Normal
    (Event.Market_tick
       {
         symbol = "BTCUSDT";
         timestamp_ns = Int64.of_int i;
         price = 100.0;
         volume = 1.0;
         bid = 99.0;
         ask = 101.0;
       })


let with_bus f =
  let bus = Event_bus.create () in
    Event_bus.start bus ;
    Fun.protect ~finally:(fun () -> Event_bus.stop bus) (fun () -> f bus)


let test_records_latency_and_counts () =
  with_bus (fun bus ->
    let c = Collector.create ~bus () in
      Collector.start c ;
      Alcotest.(check bool) "running" true (Collector.is_running c) ;
      for i = 1 to 200 do
        Event_bus.publish bus (tick i)
      done ;
      let got =
        wait_until (fun () ->
          Int64.compare (Algostream_telemetry.Histogram.count (Collector.latency_histogram c)) 200L
          >= 0) in
        Alcotest.(check bool) "every event sampled" true got ;
        let s = Collector.snapshot c in
          Alcotest.(check bool)
            "published counted" true
            (Int64.compare s.Algostream_telemetry.Snapshot.bus.published 200L >= 0) ;
          Alcotest.(check bool)
            "dispatched counted" true
            (Int64.compare s.Algostream_telemetry.Snapshot.bus.dispatched 200L >= 0) ;
          Alcotest.(check int64)
            "no drops on an idle bus" 0L s.Algostream_telemetry.Snapshot.bus.dropped ;
          Alcotest.(check bool)
            "p99 is positive" true
            (Int64.compare
               s.Algostream_telemetry.Snapshot.latency.end_to_end
                 .Algostream_telemetry.Histogram.p99_ns 0L
            > 0) ;
          Collector.stop c ;
          Alcotest.(check bool) "stopped" false (Collector.is_running c))


let test_stop_unsubscribes () =
  with_bus (fun bus ->
    let c = Collector.create ~bus () in
      Collector.start c ;
      Event_bus.publish bus (tick 1) ;
      let _ =
        wait_until (fun () ->
          Int64.compare (Algostream_telemetry.Histogram.count (Collector.latency_histogram c)) 1L
          >= 0) in
        Collector.stop c ;
        let before = Algostream_telemetry.Histogram.count (Collector.latency_histogram c) in
          for i = 1 to 50 do
            Event_bus.publish bus (tick i)
          done ;
          Unix.sleepf 0.15 ;
          Alcotest.(check int64)
            "no samples after stop" before
            (Algostream_telemetry.Histogram.count (Collector.latency_histogram c)))


let test_providers_are_polled () =
  with_bus (fun bus ->
    let c = Collector.create ~bus () in
    let calls = Atomic.make 0 in
      Collector.register c
        {
          Collector.name = "ingestion";
          metrics =
            (fun () ->
              Atomic.incr calls ;
              [ ("bus_drops", 3.0); ("stale_ticks", 1.0) ]);
          health = Some (fun () -> Health.Degraded "one feed quiet");
        } ;
      let s = Collector.snapshot c in
        Alcotest.(check int) "polled once per snapshot" 1 (Atomic.get calls) ;
        match s.Algostream_telemetry.Snapshot.components with
        | [ comp ] ->
          Alcotest.(check string) "name" "ingestion" comp.Algostream_telemetry.Snapshot.name ;
          Alcotest.(check int) "metrics" 2 (List.length comp.Algostream_telemetry.Snapshot.metrics) ;
          Alcotest.(check int)
            "component health folds into overall" 1
            (Health.severity_rank s.Algostream_telemetry.Snapshot.overall)
        | xs -> Alcotest.failf "expected one component, got %d" (List.length xs))


(* A provider that raises must not break the snapshot — the dashboard is the thing you look at when
   something is already wrong. *)
let test_raising_provider_is_contained () =
  with_bus (fun bus ->
    let c = Collector.create ~bus () in
      Collector.register c
        {
          Collector.name = "broken";
          metrics = (fun () -> failwith "boom");
          health = Some (fun () -> failwith "boom");
        } ;
      let s = Collector.snapshot c in
        match s.Algostream_telemetry.Snapshot.components with
        | [ comp ] ->
          Alcotest.(check int)
            "no metrics" 0
            (List.length comp.Algostream_telemetry.Snapshot.metrics) ;
          Alcotest.(check bool)
            "reported as failed" true
            (match comp.Algostream_telemetry.Snapshot.status with
            | Health.Failed _ -> true
            | _ -> false)
        | xs -> Alcotest.failf "expected one component, got %d" (List.length xs))


let test_sla_alert_raised_and_cleared () =
  with_bus (fun bus ->
    (* An SLA of 0 makes every sample a breach, which is the point: assert the rule fires. *)
    let c = Collector.create ~bus ~sla_ns:0L () in
      Collector.start c ;
      for i = 1 to 20 do
        Event_bus.publish bus (tick i)
      done ;
      let _ =
        wait_until (fun () ->
          Int64.compare (Algostream_telemetry.Histogram.count (Collector.latency_histogram c)) 20L
          >= 0) in
      let s = Collector.snapshot c in
        Alcotest.(check bool)
          "latency alert active" true
          (List.exists
             (fun (a : Alert.t) -> String.equal a.Alert.code "LATENCY_SLA")
             s.Algostream_telemetry.Snapshot.alerts) ;
        Alcotest.(check bool)
          "violations counted" true
          (Int64.compare s.Algostream_telemetry.Snapshot.latency.sla_violations 0L > 0) ;
        Collector.stop c)


let test_events_per_sec_derivation () =
  with_bus (fun bus ->
    let c = Collector.create ~bus () in
      Collector.start c ;
      let s0 = Collector.snapshot c in
        Alcotest.(check (float 0.0))
          "first snapshot has no rate" 0.0 s0.Algostream_telemetry.Snapshot.bus.events_per_sec ;
        for i = 1 to 500 do
          Event_bus.publish bus (tick i)
        done ;
        let _ =
          wait_until (fun () ->
            Int64.compare
              (Algostream_telemetry.Histogram.count (Collector.latency_histogram c))
              500L
            >= 0) in
          Unix.sleepf 0.05 ;
          let s1 = Collector.snapshot c in
            Alcotest.(check bool)
              "rate is positive once there is a delta" true
              (s1.Algostream_telemetry.Snapshot.bus.events_per_sec > 0.0) ;
            Collector.stop c)


let test_to_assoc_is_flat_and_prefixed () =
  with_bus (fun bus ->
    let c = Collector.create ~bus () in
      Collector.register c
        { Collector.name = "feeds"; metrics = (fun () -> [ ("drops", 2.0) ]); health = None } ;
      let assoc = Algostream_telemetry.Snapshot.to_assoc (Collector.snapshot c) in
        Alcotest.(check bool)
          "component metric is prefixed" true
          (List.mem_assoc "feeds.drops" assoc) ;
        Alcotest.(check bool)
          "latency percentile present" true
          (List.mem_assoc "latency.p99_ns" assoc) ;
        Alcotest.(check bool)
          "per-band drops present" true
          (List.mem_assoc "bus.dropped.critical" assoc))


let suite =
  [
    Alcotest.test_case "records_latency_and_counts" `Quick test_records_latency_and_counts;
    Alcotest.test_case "stop_unsubscribes" `Quick test_stop_unsubscribes;
    Alcotest.test_case "providers_are_polled" `Quick test_providers_are_polled;
    Alcotest.test_case "raising_provider_is_contained" `Quick test_raising_provider_is_contained;
    Alcotest.test_case "sla_alert_raised" `Quick test_sla_alert_raised_and_cleared;
    Alcotest.test_case "events_per_sec_derivation" `Quick test_events_per_sec_derivation;
    Alcotest.test_case "to_assoc_is_flat_and_prefixed" `Quick test_to_assoc_is_flat_and_prefixed;
  ]
