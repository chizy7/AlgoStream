let () =
  Alcotest.run "algostream-data-ingestion"
    [
      ("symbol_intern", Test_symbol_intern.suite);
      ("rate_limiter", Test_rate_limiter.suite);
      ("data_quality", Test_data_quality.suite);
      ("binance_parser", Test_binance_parser.suite);
      ("coinbase_parser", Test_coinbase_parser.suite);
      ("connection_supervisor", Test_connection_supervisor.suite);
    ]
