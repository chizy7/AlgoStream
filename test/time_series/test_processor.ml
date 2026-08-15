module EB = Algostream_infrastructure_event_bus
module Event_bus = EB.Event_bus
module Event = EB.Event_types.Event
module Priority = EB.Event_types.Priority
module P = Algostream_time_series.Processor
module Bar = Algostream_time_series.Bar

let interval_ns = 1_000_000_000L (* 1s *)

let mk_market_tick ~symbol ~ts ~price =
  Event.create ~priority:Priority.Normal
    (Event.Market_tick
       { symbol; timestamp_ns = ts; price; volume = 1.0; bid = price -. 0.05; ask = price +. 0.05 })


let wait_until ?(budget_ms = 5000) pred =
  let deadline = Unix.gettimeofday () +. (float_of_int budget_ms /. 1000.0) in
  let rec loop () =
    if pred () then true
    else if Unix.gettimeofday () > deadline then false
    else (
      Unix.sleepf 0.005 ;
      loop ()) in
    loop ()


let test_emits_bars () =
  let bus = Event_bus.create () in
    Event_bus.start bus ;
    let proc = P.start ~bus ~intervals_ns:[ interval_ns ] () in
      for i = 0 to 5 do
        let tick =
          mk_market_tick ~symbol:"BTC" ~ts:(Int64.of_int (i * 1_500_000_000)) ~price:100.0 in
          Event_bus.publish bus tick
      done ;
      let ok =
        wait_until (fun () ->
          match P.bars proc ~symbol:"BTC" ~interval_ns with
          | Some b -> Array.length b >= 3
          | None -> false) in
        P.stop proc ;
        Event_bus.stop bus ;
        Alcotest.(check bool) "bars eventually populated" true ok


let test_unknown_symbol_returns_none () =
  let bus = Event_bus.create () in
    Event_bus.start bus ;
    let proc = P.start ~bus () in
    let r = P.bars proc ~symbol:"NEVER_SEEN" ~interval_ns in
      P.stop proc ;
      Event_bus.stop bus ;
      Alcotest.(check bool) "None for unknown" true (Option.is_none r)


let suite =
  [
    Alcotest.test_case "emits_bars" `Quick test_emits_bars;
    Alcotest.test_case "unknown_symbol_returns_none" `Quick test_unknown_symbol_returns_none;
  ]
