module EB = Algostream_infrastructure_event_bus
module Event_bus = EB.Event_bus
module Event = EB.Event_types.Event
module Priority = EB.Event_types.Priority
module Data_source = Algostream_backtest.Data_source
module Latency = Algostream_backtest.Latency
module Slippage = Algostream_backtest.Slippage
module Venue = Algostream_order_management.Venue
module Instance = Algostream_runtime.Instance
module Supervisor = Algostream_runtime.Supervisor
module Snapshot = Algostream_runtime.Snapshot
module Translate = Algostream_runtime.Translate

let wait_until ?(budget_us = 5_000_000) pred =
  let deadline = Unix.gettimeofday () +. (float_of_int budget_us /. 1_000_000.0) in
  let rec loop () =
    if pred () then true
    else if Unix.gettimeofday () > deadline then false
    else (
      Unix.sleepf 0.001 ;
      loop ()) in
    loop ()


let venue = Venue.binance_spot

let make_instance id =
  let config =
    {
      (Instance.default_config ~strategy_id:id ~venue ~initial_capital:50_000.0) with
      Instance.slippage = Slippage.Spread_fraction 1.0;
      latency = Latency.zero;
      risk_limits = None;
      nav_sample_interval_ns = 0L;
    } in
    Instance.create (module Test_parity.Ping_pong) ~params:1.0 ~config


let tick i =
  let px = 100.0 +. (float_of_int i *. 0.01) in
    Event.create ~priority:Priority.Normal
      (Event.Market_tick
         {
           symbol = "TESTUSD";
           timestamp_ns = Int64.of_int ((i + 1) * 1_000_000_000);
           price = px;
           volume = 25.0;
           bid = px -. 0.01;
           ask = px +. 0.01;
         })


let test_translate_filters_non_market () =
  Alcotest.(check bool)
    "heartbeat is not market data" false
    (Translate.is_market_payload Event.Heartbeat) ;
  Alcotest.(check bool)
    "tick is" true
    (Translate.is_market_payload
       (Event.Market_tick
          { symbol = "X"; timestamp_ns = 1L; price = 1.0; volume = 1.0; bid = 0.9; ask = 1.1 })) ;
  Alcotest.(check bool)
    "heartbeat translates to nothing" true
    (Option.is_none (Translate.of_payload Event.Heartbeat)) ;
  (* A non-positive quote means "unknown", not "the market is at zero". *)
  match
    Translate.of_payload
      (Event.Market_tick
         { symbol = "X"; timestamp_ns = 5L; price = 10.0; volume = 1.0; bid = 0.0; ask = 0.0 })
  with
  | Some (Data_source.Tick { bid; ask; _ }) ->
    Alcotest.(check bool) "zero bid becomes None" true (Option.is_none bid) ;
    Alcotest.(check bool) "zero ask becomes None" true (Option.is_none ask)
  | _ -> Alcotest.fail "expected a Tick record"


let with_bus f =
  let bus = Event_bus.create () in
    Event_bus.start bus ;
    Fun.protect ~finally:(fun () -> Event_bus.stop bus) (fun () -> f bus)


let test_drives_instances_from_the_bus () =
  with_bus (fun bus ->
    let sup = Supervisor.create ~bus () in
    let inst = make_instance "s1" in
      ignore (Supervisor.add sup inst : bool) ;
      for i = 0 to 99 do
        Event_bus.publish bus (tick i)
      done ;
      let got = wait_until (fun () -> (Instance.snapshot inst).Snapshot.n_fills >= 2) in
        Alcotest.(check bool) "both orders filled through the bus" true got ;
        let s = Supervisor.snapshot sup in
          Alcotest.(check int) "one instance in the aggregate" 1 (List.length s.Snapshot.instances) ;
          Alcotest.(check bool) "aggregate nav is populated" true (s.Snapshot.total_nav > 0.0) ;
          Alcotest.(check int) "nothing dropped" 0 (Supervisor.dropped_full_queue sup) ;
          Supervisor.stop sup)


(* Pausing must stop the strategy emitting but keep its state, so resume continues rather than
   restarting. *)
let test_pause_stops_emission_but_keeps_state () =
  with_bus (fun bus ->
    let sup = Supervisor.create ~bus () in
    let inst = make_instance "s2" in
      ignore (Supervisor.add sup inst : bool) ;
      Alcotest.(check bool) "pause finds the instance" true (Supervisor.pause sup ~strategy_id:"s2") ;
      Alcotest.(check bool)
        "unknown id reports false" false
        (Supervisor.pause sup ~strategy_id:"nope") ;
      for i = 0 to 99 do
        Event_bus.publish bus (tick i)
      done ;
      let drained = wait_until (fun () -> (Instance.snapshot inst).Snapshot.n_events >= 100) in
        Alcotest.(check bool) "events still processed while paused" true drained ;
        let paused = Instance.snapshot inst in
          Alcotest.(check int) "no orders submitted while paused" 0 paused.Snapshot.n_submitted ;
          Alcotest.(check int) "no fills while paused" 0 paused.Snapshot.n_fills ;
          Alcotest.(check string)
            "lifecycle reported" "paused"
            (Snapshot.lifecycle_to_string paused.Snapshot.lifecycle) ;
          (* The tick counter inside the strategy kept advancing, so resuming does not replay. *)
          Alcotest.(check bool) "resume finds it" true (Supervisor.resume sup ~strategy_id:"s2") ;
          Alcotest.(check string)
            "lifecycle back to running" "running"
            (Snapshot.lifecycle_to_string (Instance.snapshot inst).Snapshot.lifecycle) ;
          Supervisor.stop sup)


let test_allocation () =
  with_bus (fun bus ->
    let sup = Supervisor.create ~bus () in
      ignore (Supervisor.add sup (make_instance "a") : bool) ;
      ignore (Supervisor.add sup (make_instance "b") : bool) ;
      let split = Supervisor.allocate_evenly sup ~total:80_000.0 in
        Alcotest.(check int) "two allocations" 2 (List.length split) ;
        List.iter (fun (_, v) -> Alcotest.(check (float 1e-9)) "evenly split" 40_000.0 v) split ;
        Alcotest.(check bool)
          "explicit set works" true
          (Supervisor.set_allocation sup ~strategy_id:"a" 12_345.0) ;
        (match Supervisor.find sup ~strategy_id:"a" with
        | Some i ->
          Alcotest.(check (float 1e-9))
            "allocation reflected in the snapshot" 12_345.0
            (Instance.snapshot i).Snapshot.allocation
        | None -> Alcotest.fail "instance a missing") ;
        Supervisor.stop sup)


(* Regression: the aggregate used to be a cache written only by the drain loop, so a control action
   taken while the feed was quiet returned ok and then kept reporting the old lifecycle. *)
let test_control_is_visible_without_new_events () =
  with_bus (fun bus ->
    let sup = Supervisor.create ~bus () in
      ignore (Supervisor.add sup (make_instance "quiet") : bool) ;
      (* No events at all — the drain loop has nothing to react to. *)
      Alcotest.(check string)
        "starts running" "running"
        (Snapshot.lifecycle_to_string
           (List.hd (Supervisor.snapshot sup).Snapshot.instances).Snapshot.lifecycle) ;
      Alcotest.(check bool) "pause accepted" true (Supervisor.pause sup ~strategy_id:"quiet") ;
      Alcotest.(check string)
        "aggregate reflects the pause immediately" "paused"
        (Snapshot.lifecycle_to_string
           (List.hd (Supervisor.snapshot sup).Snapshot.instances).Snapshot.lifecycle) ;
      Alcotest.(check bool)
        "allocation too" true
        (Supervisor.set_allocation sup ~strategy_id:"quiet" 777.0) ;
      Alcotest.(check (float 1e-9))
        "allocation visible" 777.0
        (List.hd (Supervisor.snapshot sup).Snapshot.instances).Snapshot.allocation ;
      Supervisor.stop sup)


let test_stop_is_idempotent () =
  with_bus (fun bus ->
    let sup = Supervisor.create ~bus () in
    let inst = make_instance "s3" in
      ignore (Supervisor.add sup inst : bool) ;
      Alcotest.(check bool) "running" true (Supervisor.is_running sup) ;
      Supervisor.stop sup ;
      Supervisor.stop sup ;
      Alcotest.(check bool) "stopped" false (Supervisor.is_running sup) ;
      Alcotest.(check string)
        "instance stopped too" "stopped"
        (Snapshot.lifecycle_to_string (Instance.snapshot inst).Snapshot.lifecycle))


let suite =
  [
    Alcotest.test_case "translate_filters_non_market" `Quick test_translate_filters_non_market;
    Alcotest.test_case "drives_instances_from_the_bus" `Quick test_drives_instances_from_the_bus;
    Alcotest.test_case "pause_stops_emission_but_keeps_state" `Quick
      test_pause_stops_emission_but_keeps_state;
    Alcotest.test_case "allocation" `Quick test_allocation;
    Alcotest.test_case "control_is_visible_without_new_events" `Quick
      test_control_is_visible_without_new_events;
    Alcotest.test_case "stop_is_idempotent" `Quick test_stop_is_idempotent;
  ]
