let () =
  Alcotest.run "algostream-analytics"
    [
      ("filters", Test_filters.suite);
      ("rolling", Test_rolling.suite);
      ("outlier", Test_outlier.suite);
      ("volatility", Test_volatility.suite);
      ("regime", Test_regime.suite);
      ("processor", Test_processor.suite);
      ("determinism", Test_determinism.suite);
    ]
