let () =
  Alcotest.run "algostream-montecarlo"
    [
      ("pool", Test_pool.suite);
      ("path", Test_path.suite);
      ("regime_sim", Test_regime_sim.suite);
      ("determinism", Test_determinism.suite);
      ("comparative", Test_comparative.suite);
    ]
