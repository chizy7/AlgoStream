let () = Alcotest.run "algostream-persistence" [ ("audit_log", Test_audit_log.suite) ]
