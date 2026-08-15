let () =
  Alcotest.run "algostream-advanced-models"
    [
      ("special", Test_special.suite);
      ("distribution", Test_distribution.suite);
      ("nelder_mead", Test_nelder_mead.suite);
      ("eig", Test_eig.suite);
      ("pca", Test_pca.suite);
      ("kalman_hedge", Test_kalman_hedge.suite);
      ("garch11", Test_garch11.suite);
      ("ou", Test_ou.suite);
      ("hypothesis_test", Test_hypothesis_test.suite);
      ("determinism", Test_determinism.suite);
    ]
