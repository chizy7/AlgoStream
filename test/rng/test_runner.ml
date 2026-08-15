let () =
  Alcotest.run "algostream-rng"
    [
      ("rng", Test_rng.suite);
      ("substream", Test_substream.suite);
      ("reference_vectors", Test_reference_vectors.suite);
      ("determinism", Test_determinism.suite);
    ]
