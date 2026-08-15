let () =
  Alcotest.run "algostream-pairs"
    [
      ("ols", Test_ols.suite);
      ("adf", Test_adf.suite);
      ("engle_granger", Test_engle_granger.suite);
      ("johansen_stub", Test_johansen_stub.suite);
      ("spread", Test_spread.suite);
      ("hedge_ratio", Test_hedge_ratio.suite);
      ("correlation", Test_correlation.suite);
      ("mean_reversion", Test_mean_reversion.suite);
      ("selection", Test_selection.suite);
      ("per_pair", Test_per_pair.suite);
      ("processor", Test_processor.suite);
      ("determinism", Test_determinism.suite);
    ]
