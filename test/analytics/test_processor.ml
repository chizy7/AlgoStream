module EB = Algostream_infrastructure_event_bus
module Event_bus = EB.Event_bus
module Event = EB.Event_types.Event
module Priority = EB.Event_types.Priority
module Proc = Algostream_analytics.Processor
module Snap = Algostream_analytics.Snapshot

let make_market_tick ~symbol ~ts ~price ~bid ~ask ~volume =
  Event.create ~priority:Priority.Normal
    (Event.Market_tick { symbol; timestamp_ns = ts; price; volume; bid; ask })


(* Generous budget — CI runners (especially OCaml 5.0.x on macOS) are noticeably slower than Apple
   Silicon dev. The test asserts eventual snapshot population, so a longer poll window absorbs
   scheduler jitter without changing what the test actually verifies. *)
let wait_until ?(budget_us = 5_000_000) pred =
  let deadline = Unix.gettimeofday () +. (float_of_int budget_us /. 1_000_000.0) in
  let rec loop () =
    if pred () then true
    else if Unix.gettimeofday () > deadline then false
    else (
      Unix.sleepf 0.001 ;
      loop ()) in
    loop ()


let test_subscribes_and_processes () =
  let bus = Event_bus.create () in
    Event_bus.start bus ;
    let proc = Proc.start ~bus () in
      for i = 1 to 200 do
        let p = 100.0 +. (float_of_int i *. 0.01) in
        let tick =
          make_market_tick ~symbol:"BTC"
            ~ts:(Int64.of_int (i * 2_000_000)) (* 2ms apart so snapshot throttle releases *)
            ~price:p ~bid:(p -. 0.05) ~ask:(p +. 0.05) ~volume:1.0 in
          Event_bus.publish bus tick
      done ;
      let ok =
        wait_until (fun () ->
          let s = Proc.snapshot proc ~symbol:"BTC" in
            s.n_ticks >= 100) in
        Proc.stop proc ;
        Event_bus.stop bus ;
        Alcotest.(check bool) "snapshot eventually populated" true ok


let test_unknown_symbol_returns_empty () =
  let bus = Event_bus.create () in
    Event_bus.start bus ;
    let proc = Proc.start ~bus () in
    let s = Proc.snapshot proc ~symbol:"NEVER_SEEN" in
      Proc.stop proc ;
      Event_bus.stop bus ;
      Alcotest.(check int) "empty snapshot has n_ticks=0" 0 s.n_ticks


let test_stats_track_observed () =
  let bus = Event_bus.create () in
    Event_bus.start bus ;
    let proc = Proc.start ~bus () in
      for i = 1 to 50 do
        let tick =
          make_market_tick ~symbol:"BTC"
            ~ts:(Int64.of_int (i * 2_000_000))
            ~price:100.0 ~bid:99.95 ~ask:100.05 ~volume:1.0 in
          Event_bus.publish bus tick
      done ;
      let _ = wait_until (fun () -> (Proc.stats proc).ticks_observed >= 50L) in
      let s = Proc.stats proc in
        Proc.stop proc ;
        Event_bus.stop bus ;
        Alcotest.(check bool) "observed >= 50" true (Int64.compare s.ticks_observed 50L >= 0)


let suite =
  [
    Alcotest.test_case "subscribes_and_processes" `Quick test_subscribes_and_processes;
    Alcotest.test_case "unknown_symbol_returns_empty" `Quick test_unknown_symbol_returns_empty;
    Alcotest.test_case "stats_track_observed" `Quick test_stats_track_observed;
  ]
