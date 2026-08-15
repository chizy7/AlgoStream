let () =
  Alcotest.run "algostream-runtime"
    [ ("parity", Test_parity.suite); ("supervisor", Test_supervisor.suite) ]
