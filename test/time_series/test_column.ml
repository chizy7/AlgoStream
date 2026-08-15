module C = Algostream_time_series.Column

let test_basic_push_freeze () =
  let c = C.create ~capacity:4 () in
    C.push c 1.0 ;
    C.push c 2.0 ;
    C.push c 3.0 ;
    Alcotest.(check int) "length" 3 (C.length c) ;
    let frozen = C.freeze c in
      Alcotest.(check int) "frozen length" 3 (Bigarray.Array1.dim frozen) ;
      Alcotest.(check (float 1e-9)) "value 0" 1.0 (Bigarray.Array1.get frozen 0) ;
      Alcotest.(check (float 1e-9)) "value 2" 3.0 (Bigarray.Array1.get frozen 2)


let test_grow_beyond_initial_capacity () =
  let c = C.create ~capacity:2 () in
    for i = 1 to 1000 do
      C.push c (float_of_int i)
    done ;
    Alcotest.(check int) "length 1000" 1000 (C.length c) ;
    let frozen = C.freeze c in
      Alcotest.(check (float 1e-9)) "first" 1.0 (Bigarray.Array1.get frozen 0) ;
      Alcotest.(check (float 1e-9)) "last" 1000.0 (Bigarray.Array1.get frozen 999)


let test_freeze_independence () =
  (* freeze produces a copy; subsequent pushes must not mutate it *)
  let c = C.create ~capacity:4 () in
    C.push c 1.0 ;
    let frozen = C.freeze c in
      C.push c 2.0 ;
      C.push c 3.0 ;
      Alcotest.(check int) "frozen length unchanged" 1 (Bigarray.Array1.dim frozen) ;
      Alcotest.(check (float 1e-9)) "frozen value unchanged" 1.0 (Bigarray.Array1.get frozen 0)


let test_int64_col () =
  let c = C.Int64_col.create ~capacity:4 () in
    C.Int64_col.push c 1_000_000L ;
    C.Int64_col.push c 2_000_000L ;
    let frozen = C.Int64_col.freeze c in
      Alcotest.(check int64) "first ts" 1_000_000L (Bigarray.Array1.get frozen 0) ;
      Alcotest.(check int64) "second ts" 2_000_000L (Bigarray.Array1.get frozen 1)


let suite =
  [
    Alcotest.test_case "basic_push_freeze" `Quick test_basic_push_freeze;
    Alcotest.test_case "grow_beyond_initial_capacity" `Quick test_grow_beyond_initial_capacity;
    Alcotest.test_case "freeze_independence" `Quick test_freeze_independence;
    Alcotest.test_case "int64_col" `Quick test_int64_col;
  ]
