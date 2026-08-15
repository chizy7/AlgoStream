let () =
  Alcotest.run "algostream-order-management"
    [
      ("venue", Test_venue.suite);
      ("order_state", Test_order_state.suite);
      ("position_sizing", Test_position_sizing.suite);
      ("routing", Test_routing.suite);
      ("execution_quality", Test_execution_quality.suite);
      ("book_impact", Test_book_impact.suite);
      ("determinism", Test_determinism.suite);
    ]
