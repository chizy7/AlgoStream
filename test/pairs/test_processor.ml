open Algostream_pairs
module EB = Algostream_infrastructure_event_bus
module Event_bus = EB.Event_bus
module Event = EB.Event_types.Event
module Priority = EB.Event_types.Priority
module Proc = Processor

let make_tick ~symbol ~ts ~price =
  Event.create ~priority:Priority.Normal
    (Event.Market_tick
       { symbol; timestamp_ns = ts; price; volume = 1.0; bid = price -. 0.05; ask = price +. 0.05 })


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
    let pid = Helpers.pair "BTC" "ETH" in
    let pairs =
      [
        {
          Proc.pair = pid;
          y_raw = "BTC";
          (* Pair_id.y is the lex-smaller canonical, so y = BTC/USD *)
          x_raw = "ETH";
        };
      ] in
    let proc = Proc.start ~bus ~pairs () in
      for i = 1 to 300 do
        let ts = Int64.of_int (i * 2_000_000) in
        let px_btc = 30_000.0 +. (float_of_int i *. 0.5) in
        let px_eth = 2_000.0 +. (float_of_int i *. 0.05) in
          Event_bus.publish bus (make_tick ~symbol:"BTC" ~ts ~price:px_btc) ;
          Event_bus.publish bus (make_tick ~symbol:"ETH" ~ts ~price:px_eth)
      done ;
      let ok =
        wait_until (fun () ->
          let s = Proc.snapshot proc ~pair:pid in
            s.n_ticks >= 100) in
        Proc.stop proc ;
        Proc.stop proc ;
        (* idempotent *)
        Event_bus.stop bus ;
        Alcotest.(check bool) "snapshot eventually populated" true ok


let test_unknown_pair_returns_empty () =
  let bus = Event_bus.create () in
    Event_bus.start bus ;
    let pid_used = Helpers.pair "BTC" "ETH" in
    let pid_unknown = Helpers.pair "SOL" "ADA" in
    let proc =
      Proc.start ~bus ~pairs:[ { Proc.pair = pid_used; y_raw = "BTC"; x_raw = "ETH" } ] () in
    let s = Proc.snapshot proc ~pair:pid_unknown in
      Proc.stop proc ;
      Event_bus.stop bus ;
      Alcotest.(check int) "n_ticks=0" 0 s.n_ticks


let test_stats_track () =
  let bus = Event_bus.create () in
    Event_bus.start bus ;
    let pid = Helpers.pair "BTC" "ETH" in
    let proc = Proc.start ~bus ~pairs:[ { Proc.pair = pid; y_raw = "BTC"; x_raw = "ETH" } ] () in
      for i = 1 to 20 do
        Event_bus.publish bus
          (make_tick ~symbol:"BTC" ~ts:(Int64.of_int (i * 2_000_000)) ~price:100.0) ;
        Event_bus.publish bus
          (make_tick ~symbol:"ETH" ~ts:(Int64.of_int (i * 2_000_000)) ~price:50.0)
      done ;
      let _ = wait_until (fun () -> (Proc.stats proc).ticks_observed >= 40L) in
      let s = Proc.stats proc in
        Proc.stop proc ;
        Event_bus.stop bus ;
        Alcotest.(check bool) "observed ≥ 40" true (Int64.compare s.ticks_observed 40L >= 0) ;
        Alcotest.(check int) "1 active pair" 1 s.active_pairs


let test_max_active_pairs_invalid_arg () =
  let bus = Event_bus.create () in
    Event_bus.start bus ;
    let cfg = { Config.default with max_active_pairs = 1 } in
    let p1 = { Proc.pair = Helpers.pair "AA" "BB"; y_raw = "AA"; x_raw = "BB" } in
    let p2 = { Proc.pair = Helpers.pair "CC" "DD"; y_raw = "CC"; x_raw = "DD" } in
      (try
         let _ = Proc.start ~bus ~pairs:[ p1; p2 ] ~config:cfg () in
           Alcotest.fail "expected invalid_arg"
       with Invalid_argument _ -> ()) ;
      Event_bus.stop bus


let suite =
  [
    Alcotest.test_case "subscribes_and_processes" `Quick test_subscribes_and_processes;
    Alcotest.test_case "unknown_pair_returns_empty" `Quick test_unknown_pair_returns_empty;
    Alcotest.test_case "stats_track" `Quick test_stats_track;
    Alcotest.test_case "max_active_pairs_invalid_arg" `Quick test_max_active_pairs_invalid_arg;
  ]
