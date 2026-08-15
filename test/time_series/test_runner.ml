let () =
  Alcotest.run "algostream-time-series"
    [
      ("column", Test_column.suite);
      ("bar_builder", Test_bar_builder.suite);
      ("interpolate", Test_interpolate.suite);
      ("align", Test_align.suite);
      ("compress", Test_compress.suite);
      ("processor", Test_processor.suite);
    ]
