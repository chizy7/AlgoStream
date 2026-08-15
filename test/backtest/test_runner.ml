let () =
  Alcotest.run "algostream-backtest"
    [
      ("data_source", Test_data_source.suite);
      ("fill_engine", Test_fill_engine.suite);
      ("engine", Test_engine.suite);
      ("determinism", Test_determinism.suite);
    ]
