let () =
  Alcotest.run "algostream-telemetry"
    [
      ("histogram", Test_histogram.suite);
      ("health", Test_health.suite);
      ("alert", Test_alert.suite);
      ("collector", Test_collector.suite);
    ]
