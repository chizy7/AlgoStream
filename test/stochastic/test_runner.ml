let () =
  Alcotest.run "algostream-stochastic"
    [
      ("variate", Test_variate.suite);
      ("cholesky", Test_cholesky.suite);
      ("resample", Test_resample.suite);
      ("quantile", Test_quantile.suite);
      ("determinism", Test_determinism.suite);
    ]
