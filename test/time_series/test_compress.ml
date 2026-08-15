module C = Algostream_time_series.Compress

let mk_float arr =
  let n = Array.length arr in
  let b = Bigarray.Array1.create Bigarray.float64 Bigarray.c_layout n in
    Array.iteri (fun i v -> Bigarray.Array1.set b i v) arr ;
    b


let mk_int64 arr =
  let n = Array.length arr in
  let b = Bigarray.Array1.create Bigarray.int64 Bigarray.c_layout n in
    Array.iteri (fun i v -> Bigarray.Array1.set b i v) arr ;
    b


let assert_float_eq ~msg got expected =
  let g = Int64.bits_of_float got in
  let e = Int64.bits_of_float expected in
    if not (Int64.equal g e) then
      Alcotest.failf "%s: bits mismatch (got %g, expected %g)" msg got expected


let test_float_round_trip_basic () =
  let arr = mk_float [| 100.0; 100.01; 100.02; 99.99; 100.0 |] in
  let b = C.encode_float arr in
  let arr2 = C.decode_float b in
    Alcotest.(check int) "length" (Bigarray.Array1.dim arr) (Bigarray.Array1.dim arr2) ;
    for i = 0 to Bigarray.Array1.dim arr - 1 do
      assert_float_eq ~msg:(Printf.sprintf "[%d]" i) (Bigarray.Array1.get arr2 i)
        (Bigarray.Array1.get arr i)
    done


let test_float_round_trip_extremes () =
  let arr =
    mk_float
      [|
        0.0;
        Float.neg 0.0;
        Float.nan;
        Float.infinity;
        Float.neg_infinity;
        Float.min_float;
        Float.max_float;
        1e-300;
        -1.5;
      |] in
  let b = C.encode_float arr in
  let arr2 = C.decode_float b in
    for i = 0 to Bigarray.Array1.dim arr - 1 do
      let g = Int64.bits_of_float (Bigarray.Array1.get arr2 i) in
      let e = Int64.bits_of_float (Bigarray.Array1.get arr i) in
        Alcotest.(check int64) (Printf.sprintf "[%d] bits-equal" i) e g
    done


let test_float_round_trip_random () =
  let rng = Random.State.make [| 42 |] in
  let n = 1000 in
  let arr = mk_float (Array.init n (fun _ -> Random.State.float rng 200.0 -. 100.0)) in
  let b = C.encode_float arr in
  let arr2 = C.decode_float b in
    for i = 0 to n - 1 do
      let g = Int64.bits_of_float (Bigarray.Array1.get arr2 i) in
      let e = Int64.bits_of_float (Bigarray.Array1.get arr i) in
        if not (Int64.equal g e) then Alcotest.failf "[%d] random round-trip diverged" i
    done


let test_int64_round_trip () =
  let arr =
    mk_int64 [| 1_000_000_000L; 1_001_000_000L; 1_002_500_000L; 2_000_000_000L; 2_000_000_500L |]
  in
  let b = C.encode_int64 arr in
  let arr2 = C.decode_int64 b in
    for i = 0 to Bigarray.Array1.dim arr - 1 do
      Alcotest.(check int64)
        (Printf.sprintf "[%d]" i) (Bigarray.Array1.get arr i) (Bigarray.Array1.get arr2 i)
    done


let test_empty () =
  let arr = mk_float [||] in
  let b = C.encode_float arr in
  let arr2 = C.decode_float b in
    Alcotest.(check int) "empty length" 0 (Bigarray.Array1.dim arr2)


let suite =
  [
    Alcotest.test_case "float_round_trip_basic" `Quick test_float_round_trip_basic;
    Alcotest.test_case "float_round_trip_extremes" `Quick test_float_round_trip_extremes;
    Alcotest.test_case "float_round_trip_random" `Quick test_float_round_trip_random;
    Alcotest.test_case "int64_round_trip" `Quick test_int64_round_trip;
    Alcotest.test_case "empty" `Quick test_empty;
  ]
