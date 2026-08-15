module I = Algostream_time_series.Interpolate

let mk_validity bits =
  let n = Array.length bits in
  let v = Bigarray.Array1.create Bigarray.int8_unsigned Bigarray.c_layout n in
    Array.iteri (fun i b -> Bigarray.Array1.set v i b) bits ;
    v


let mk_col floats =
  let n = Array.length floats in
  let c = Bigarray.Array1.create Bigarray.float64 Bigarray.c_layout n in
    Array.iteri (fun i f -> Bigarray.Array1.set c i f) floats ;
    c


let test_forward_fill () =
  let validity = mk_validity [| 1; 0; 0; 1; 0 |] in
  let col = mk_col [| 1.0; 0.0; 0.0; 4.0; 0.0 |] in
  let n = I.fill_in_place ~validity ~col ~strategy:Forward_fill in
    Alcotest.(check int) "filled count" 3 n ;
    Alcotest.(check (float 1e-9)) "[1] forward-fill" 1.0 (Bigarray.Array1.get col 1) ;
    Alcotest.(check (float 1e-9)) "[2] forward-fill" 1.0 (Bigarray.Array1.get col 2) ;
    Alcotest.(check (float 1e-9)) "[4] forward-fill" 4.0 (Bigarray.Array1.get col 4)


let test_linear_interp () =
  let validity = mk_validity [| 1; 0; 0; 1 |] in
  let col = mk_col [| 0.0; 0.0; 0.0; 9.0 |] in
  let n = I.fill_in_place ~validity ~col ~strategy:Linear in
    Alcotest.(check int) "filled count" 2 n ;
    Alcotest.(check (float 1e-9)) "[1] linear" 3.0 (Bigarray.Array1.get col 1) ;
    Alcotest.(check (float 1e-9)) "[2] linear" 6.0 (Bigarray.Array1.get col 2)


let test_leave_nan () =
  let validity = mk_validity [| 1; 0; 1 |] in
  let col = mk_col [| 1.0; 0.0; 3.0 |] in
  let _ = I.fill_in_place ~validity ~col ~strategy:Leave_nan in
    Alcotest.(check bool) "[1] is NaN" true (Float.is_nan (Bigarray.Array1.get col 1))


let suite =
  [
    Alcotest.test_case "forward_fill" `Quick test_forward_fill;
    Alcotest.test_case "linear_interp" `Quick test_linear_interp;
    Alcotest.test_case "leave_nan" `Quick test_leave_nan;
  ]
