let () =
  Alcotest.run "algostream-network"
    [ ("json", Test_json.suite); ("routing", Test_routing.suite); ("bind", Test_bind.suite) ]
