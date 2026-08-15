module Cholesky = Algostream_stochastic.Cholesky

let mat_mul_lt l =
  (* L * L^T *)
  let n = Array.length l in
    Array.init n (fun i ->
      Array.init n (fun j ->
        let s = ref 0.0 in
          for k = 0 to min i j do
            s := !s +. (l.(i).(k) *. l.(j).(k))
          done ;
          !s))


let check_roundtrip name a =
  match Cholesky.factor a with
  | Error _ -> Alcotest.failf "%s: factorization failed on a positive-definite matrix" name
  | Ok l ->
    let recon = mat_mul_lt l in
      Array.iteri
        (fun i row ->
          Array.iteri
            (fun j v ->
              Alcotest.(check (float 1e-9))
                (Printf.sprintf "%s: L*L^T[%d][%d]" name i j)
                v
                recon.(i).(j))
            row)
        a


let test_roundtrip_2x2 () = check_roundtrip "2x2" [| [| 4.0; 2.0 |]; [| 2.0; 3.0 |] |]

let test_roundtrip_3x3 () =
  check_roundtrip "3x3" [| [| 25.0; 15.0; -5.0 |]; [| 15.0; 18.0; 0.0 |]; [| -5.0; 0.0; 11.0 |] |]


let test_identity () =
  match Cholesky.factor [| [| 1.0; 0.0 |]; [| 0.0; 1.0 |] |] with
  | Error _ -> Alcotest.fail "identity should factor"
  | Ok l ->
    Alcotest.(check (float 1e-12)) "L[0][0]" 1.0 l.(0).(0) ;
    Alcotest.(check (float 1e-12)) "L[1][1]" 1.0 l.(1).(1) ;
    Alcotest.(check (float 1e-12)) "upper triangle is zero" 0.0 l.(0).(1)


let test_is_lower_triangular () =
  match Cholesky.factor [| [| 4.0; 2.0 |]; [| 2.0; 3.0 |] |] with
  | Error _ -> Alcotest.fail "factorization failed"
  | Ok l ->
    Array.iteri
      (fun i row ->
        Array.iteri
          (fun j v ->
            if j > i then
              Alcotest.(check (float 1e-15))
                (Printf.sprintf "L[%d][%d] above diagonal is 0" i j)
                0.0 v)
          row)
      l


let test_rejects_indefinite () =
  (* Correlation of 2 is impossible; the leading minor test must catch it. *)
  match Cholesky.factor [| [| 1.0; 2.0 |]; [| 2.0; 1.0 |] |] with
  | Error (`Not_positive_definite i) -> Alcotest.(check int) "fails at the second pivot" 1 i
  | Error _ -> Alcotest.fail "wrong error"
  | Ok _ -> Alcotest.fail "an indefinite matrix must not factor"


let test_rejects_non_square () =
  match Cholesky.factor [| [| 1.0; 0.0; 0.0 |]; [| 0.0; 1.0; 0.0 |] |] with
  | Error (`Not_square (r, c)) -> Alcotest.(check bool) "reports the shape" true (r <> c)
  | _ -> Alcotest.fail "a non-square matrix must be rejected"


(* A correlation matrix built from finite samples is routinely indefinite by a rounding epsilon. The
   ridge exists to turn that into a clean factorization rather than a spurious failure. *)
let test_jitter_rescues_a_near_singular_matrix () =
  let a = [| [| 1.0; 1.0 |]; [| 1.0; 1.0 -. 1e-14 |] |] in
    (match Cholesky.factor a with
    | Error _ -> Alcotest.(check bool) "exact factorization fails, as expected" true true
    | Ok _ -> Alcotest.(check bool) "exact factorization happened to succeed" true true) ;
    match Cholesky.factor_jittered a with
    | Ok _ -> Alcotest.(check bool) "the ridge rescues it" true true
    | Error _ -> Alcotest.fail "jittered factorization should succeed on a near-singular matrix"


(* The ridge is deliberately small: it must NOT rescue a genuinely indefinite matrix. *)
let test_jitter_does_not_rescue_genuine_indefiniteness () =
  match Cholesky.factor_jittered [| [| 1.0; 5.0 |]; [| 5.0; 1.0 |] |] with
  | Error _ -> Alcotest.(check bool) "still rejected" true true
  | Ok _ -> Alcotest.fail "the ridge must not paper over a materially negative eigenvalue"


let test_apply_transforms_covariance () =
  match Cholesky.factor [| [| 4.0; 0.0 |]; [| 0.0; 9.0 |] |] with
  | Error _ -> Alcotest.fail "factorization failed"
  | Ok l ->
    let out = Cholesky.apply ~lower:l [| 1.0; 1.0 |] in
      Alcotest.(check (float 1e-12)) "sqrt(4) * 1" 2.0 out.(0) ;
      Alcotest.(check (float 1e-12)) "sqrt(9) * 1" 3.0 out.(1)


let test_apply_rejects_mismatch () =
  match Cholesky.factor [| [| 1.0; 0.0 |]; [| 0.0; 1.0 |] |] with
  | Error _ -> Alcotest.fail "factorization failed"
  | Ok l ->
    Alcotest.(check bool)
      "raises on a length mismatch" true
      (try
         ignore (Cholesky.apply ~lower:l [| 1.0 |]) ;
         false
       with Invalid_argument _ -> true)


let test_correlation_to_covariance () =
  let corr = [| [| 1.0; 0.5 |]; [| 0.5; 1.0 |] |] in
  let cov = Cholesky.correlation_to_covariance ~corr ~stddev:[| 2.0; 3.0 |] in
    Alcotest.(check (float 1e-12)) "diag[0] = 2^2" 4.0 cov.(0).(0) ;
    Alcotest.(check (float 1e-12)) "diag[1] = 3^2" 9.0 cov.(1).(1) ;
    Alcotest.(check (float 1e-12)) "off-diag = 0.5*2*3" 3.0 cov.(0).(1) ;
    Alcotest.(check (float 1e-12)) "symmetric" 3.0 cov.(1).(0)


let suite =
  [
    Alcotest.test_case "roundtrip_2x2" `Quick test_roundtrip_2x2;
    Alcotest.test_case "roundtrip_3x3" `Quick test_roundtrip_3x3;
    Alcotest.test_case "identity" `Quick test_identity;
    Alcotest.test_case "is_lower_triangular" `Quick test_is_lower_triangular;
    Alcotest.test_case "rejects_indefinite" `Quick test_rejects_indefinite;
    Alcotest.test_case "rejects_non_square" `Quick test_rejects_non_square;
    Alcotest.test_case "jitter_rescues_a_near_singular_matrix" `Quick
      test_jitter_rescues_a_near_singular_matrix;
    Alcotest.test_case "jitter_does_not_rescue_genuine_indefiniteness" `Quick
      test_jitter_does_not_rescue_genuine_indefiniteness;
    Alcotest.test_case "apply_transforms_covariance" `Quick test_apply_transforms_covariance;
    Alcotest.test_case "apply_rejects_mismatch" `Quick test_apply_rejects_mismatch;
    Alcotest.test_case "correlation_to_covariance" `Quick test_correlation_to_covariance;
  ]
