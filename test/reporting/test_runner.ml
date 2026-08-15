let () =
  Alcotest.run "algostream-reporting"
    [ ("export", Test_export.suite); ("live_compare", Test_live_compare.suite) ]
