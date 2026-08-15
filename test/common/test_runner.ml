let () =
  Alcotest.run "algostream-common"
    [ ("affinity", Test_affinity.suite); ("clock", Test_clock.suite); ("cli", Test_cli.suite) ]
