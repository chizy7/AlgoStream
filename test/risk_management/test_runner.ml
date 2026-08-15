let () =
  Alcotest.run "algostream-risk-management"
    [
      ("risk_limits", Test_risk_limits.suite);
      ("var", Test_var.suite);
      ("drawdown", Test_drawdown.suite);
      ("correlation_breakdown", Test_correlation_breakdown.suite);
      ("exposure", Test_exposure.suite);
      ("circuit_breaker", Test_circuit_breaker.suite);
      ("monitor", Test_monitor.suite);
      ("proprietary_models", Test_proprietary_models.suite);
      ("determinism", Test_determinism.suite);
    ]
