module EB = Algostream_infrastructure_event_bus
module Event = EB.Event_types.Event
module Priority = EB.Event_types.Priority
module Filter = EB.Subscription.Filter
module Clock = Algostream_common_utils.Time_utils.Clock
module Sleep = Algostream_common_utils.Time_utils.Sleep

(* Spin until [pred ()] is true or [budget_ns] elapses. Returns whether the predicate succeeded.
   Each iteration sleeps 100us, so this is cheap. *)
let wait_until ?(budget_ns = 500_000_000L) pred =
  let start = Clock.now_monotonic_ns () in
  let rec loop () =
    if pred () then true
    else
      let now = Clock.now_monotonic_ns () in
        if Int64.sub now start > budget_ns then false
        else (
          Sleep.sleep_us 100L ;
          loop ()) in
    loop ()


let test_publish_subscribe_roundtrip () =
  let bus = EB.Event_bus.create () in
  let received = Atomic.make 0 in
  let _id = EB.Event_bus.subscribe bus (fun _ -> Atomic.incr received) in
    EB.Event_bus.start bus ;
    EB.Event_bus.publish bus (Event.create ~priority:Priority.High Event.Heartbeat) ;
    EB.Event_bus.publish bus (Event.create ~priority:Priority.High Event.Heartbeat) ;
    let ok = wait_until (fun () -> Atomic.get received >= 2) in
      EB.Event_bus.stop bus ;
      Alcotest.(check bool) "received both" true ok ;
      Alcotest.(check int) "count" 2 (Atomic.get received)


let test_filter_excludes () =
  let bus = EB.Event_bus.create () in
  let critical_count = Atomic.make 0 in
  let _id =
    EB.Event_bus.subscribe_filtered bus (Filter.by_priority Priority.Critical) (fun _ ->
      Atomic.incr critical_count) in
    EB.Event_bus.start bus ;
    EB.Event_bus.publish bus (Event.create ~priority:Priority.Low Event.Heartbeat) ;
    EB.Event_bus.publish bus (Event.create ~priority:Priority.Critical Event.Heartbeat) ;
    EB.Event_bus.publish bus (Event.create ~priority:Priority.Normal Event.Heartbeat) ;
    let ok = wait_until (fun () -> Atomic.get critical_count >= 1) in
      EB.Event_bus.stop bus ;
      Alcotest.(check bool) "got the critical one" true ok ;
      Alcotest.(check int) "filter excluded the others" 1 (Atomic.get critical_count)


let test_unsubscribe_stops_delivery () =
  let bus = EB.Event_bus.create () in
  let count = Atomic.make 0 in
  let id = EB.Event_bus.subscribe bus (fun _ -> Atomic.incr count) in
    EB.Event_bus.start bus ;
    EB.Event_bus.publish bus (Event.create ~priority:Priority.Normal Event.Heartbeat) ;
    let _ = wait_until (fun () -> Atomic.get count >= 1) in
    let after_first = Atomic.get count in
      EB.Event_bus.unsubscribe bus id ;
      EB.Event_bus.publish bus (Event.create ~priority:Priority.Normal Event.Heartbeat) ;
      EB.Event_bus.publish bus (Event.create ~priority:Priority.Normal Event.Heartbeat) ;
      Sleep.sleep_ms 50L ;
      EB.Event_bus.stop bus ;
      Alcotest.(check int) "delivery stopped" after_first (Atomic.get count)


let test_filter_combinators () =
  let make_event sym priority =
    Event.create ~priority
      (Event.Market_tick
         { symbol = sym; timestamp_ns = 0L; price = 100.0; volume = 1.0; bid = 99.0; ask = 101.0 })
  in
  let f = Filter.and_ (Filter.by_symbol "AAPL") (Filter.min_priority Priority.High) in
    Alcotest.(check bool)
      "AAPL+High matches" true
      (Filter.matches f (make_event "AAPL" Priority.High)) ;
    Alcotest.(check bool)
      "AAPL+Critical matches (min_priority)" true
      (Filter.matches f (make_event "AAPL" Priority.Critical)) ;
    Alcotest.(check bool)
      "AAPL+Normal does not" false
      (Filter.matches f (make_event "AAPL" Priority.Normal)) ;
    Alcotest.(check bool)
      "MSFT+High does not" false
      (Filter.matches f (make_event "MSFT" Priority.High))


let test_priority_dispatch_order () =
  let bus = EB.Event_bus.create () in
  let order = ref [] in
  let mutex = Mutex.create () in
  let _id =
    EB.Event_bus.subscribe bus (fun e ->
      Mutex.lock mutex ;
      order := e.sequence_id :: !order ;
      Mutex.unlock mutex) in
    EB.Event_bus.start bus ;
    let low = Event.create ~priority:Priority.Low Event.Heartbeat in
    let crit = Event.create ~priority:Priority.Critical Event.Heartbeat in
    let normal = Event.create ~priority:Priority.Normal Event.Heartbeat in
      (* Push all three before the dispatcher loop has a chance to drain. *)
      EB.Event_bus.publish bus low ;
      EB.Event_bus.publish bus normal ;
      EB.Event_bus.publish bus crit ;
      let _ = wait_until (fun () -> List.length !order >= 3) in
        EB.Event_bus.stop bus ;
        Alcotest.(check int) "received all three" 3 (List.length !order)


let suite =
  [
    Alcotest.test_case "publish_subscribe_roundtrip" `Quick test_publish_subscribe_roundtrip;
    Alcotest.test_case "filter_excludes" `Quick test_filter_excludes;
    Alcotest.test_case "unsubscribe_stops_delivery" `Quick test_unsubscribe_stops_delivery;
    Alcotest.test_case "filter_combinators" `Quick test_filter_combinators;
    Alcotest.test_case "priority_dispatch_order" `Quick test_priority_dispatch_order;
  ]
