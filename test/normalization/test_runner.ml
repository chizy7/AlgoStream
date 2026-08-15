let () =
  Alcotest.run "algostream-normalization"
    [
      ("symbol", Test_symbol.suite);
      ("data_break", Test_data_break.suite);
      ("validator", Test_validator.suite);
      ("cross_feed", Test_cross_feed.suite);
      ("feed_health", Test_feed_health.suite);
      ("lineage", Test_lineage.suite);
    ]
