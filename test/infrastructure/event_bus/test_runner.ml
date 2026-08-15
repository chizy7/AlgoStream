let () =
  Alcotest.run "algostream-event-bus"
    [
      ("priority_queue", Test_priority_queue.suite);
      ("event_bus", Test_event_bus.suite);
      ("event_log", Test_event_log.suite);
    ]
