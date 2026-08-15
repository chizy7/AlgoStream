let () =
  Alcotest.run "algostream-domain"
    [
      ("trades", Test_trades.suite); ("portfolio", Test_portfolio.suite); ("pairs", Test_pairs.suite);
    ]
