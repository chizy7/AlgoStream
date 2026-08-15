let () =
  Alcotest.run "algostream-strategy"
    [
      ("side", Test_side.suite);
      ("action", Test_action.suite);
      ("pairs_mean_reversion", Test_pairs_mean_reversion.suite);
      ("determinism", Test_determinism.suite);
    ]
