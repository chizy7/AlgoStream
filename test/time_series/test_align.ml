module A = Algostream_time_series.Align
module S = Algostream_time_series.Series
module Bar = Algostream_time_series.Bar

let mk_bars ~symbol tss =
  Array.map
    (fun ts ->
      {
        Bar.symbol;
        open_ts = ts;
        close_ts = Int64.add ts 1_000_000_000L;
        open_ = 100.0;
        high = 101.0;
        low = 99.0;
        close = 100.5;
        volume = 1.0;
        n_ticks = 1;
        partial = false;
      })
    tss


let test_uniform_grid_basic () =
  let g = A.uniform_grid ~start_ns:0L ~end_ns:5_000_000_000L ~step_ns:1_000_000_000L in
    Alcotest.(check int) "6 points" 6 (Bigarray.Array1.dim g) ;
    Alcotest.(check int64) "first" 0L (Bigarray.Array1.get g 0) ;
    Alcotest.(check int64) "last" 5_000_000_000L (Bigarray.Array1.get g 5)


let test_align_pad_nan () =
  let s_a = S.of_bars ~symbol:"A" (mk_bars ~symbol:"A" [| 1L; 2L; 3L |]) in
  let s_b = S.of_bars ~symbol:"B" (mk_bars ~symbol:"B" [| 0L; 1L; 2L; 3L |]) in
  let g = A.uniform_grid ~start_ns:0L ~end_ns:3L ~step_ns:1L in
  let aligned = A.align_to_grid ~grid:g ~pad:Pad_nan ~gap_fill:Leave_nan [ s_a; s_b ] in
    match aligned with
    | [ a; _b ] ->
      (* a starts at ts=1 so ts=0 should be NaN *)
      let close_a = S.column a ~name:"close" |> Option.get in
        Alcotest.(check bool) "[0] NaN for A" true (Float.is_nan (Bigarray.Array1.get close_a 0))
    | _ -> Alcotest.fail "expected 2 aligned series"


let test_align_skip_until_all_present () =
  let s_a = S.of_bars ~symbol:"A" (mk_bars ~symbol:"A" [| 2L; 3L |]) in
  let s_b = S.of_bars ~symbol:"B" (mk_bars ~symbol:"B" [| 0L; 1L; 2L; 3L |]) in
  let g = A.uniform_grid ~start_ns:0L ~end_ns:3L ~step_ns:1L in
  let aligned =
    A.align_to_grid ~grid:g ~pad:Skip_until_all_present ~gap_fill:Leave_nan [ s_a; s_b ] in
    match aligned with
    | [ a; _b ] ->
      Alcotest.(check bool) "[0] invalid for A" false (S.is_valid a 0) ;
      Alcotest.(check bool) "[1] invalid for A" false (S.is_valid a 1) ;
      Alcotest.(check bool) "[2] valid for A" true (S.is_valid a 2)
    | _ -> Alcotest.fail "expected 2 aligned series"


let suite =
  [
    Alcotest.test_case "uniform_grid_basic" `Quick test_uniform_grid_basic;
    Alcotest.test_case "align_pad_nan" `Quick test_align_pad_nan;
    Alcotest.test_case "align_skip_until_all_present" `Quick test_align_skip_until_all_present;
  ]
