let () =
  Alcotest.run "algostream-performance"
    [
      ("returns", Test_returns.suite);
      ("metrics", Test_metrics.suite);
      ("drawdown_analysis", Test_drawdown_analysis.suite);
      ("benchmark_compare", Test_benchmark_compare.suite);
      ("attribution", Test_attribution.suite);
      ("consolidation", Test_consolidation.suite);
    ]
