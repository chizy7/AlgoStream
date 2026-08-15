let () =
  Alcotest.run "algostream-optimization"
    [
      ("search_space", Test_search_space.suite);
      ("search", Test_search.suite);
      ("cross_validation", Test_cross_validation.suite);
      ("walk_forward", Test_walk_forward.suite);
      ("overfitting", Test_overfitting.suite);
      ("ensemble", Test_ensemble.suite);
      ("genetic", Test_genetic.suite);
    ]
