open Algostream_advanced_models

let test_diagonal_2x2 () =
  let m = [| [| 3.0; 0.0 |]; [| 0.0; 1.0 |] |] in
  let r = Eig.jacobi_sym ~matrix:m () in
    Alcotest.(check (float 1e-10)) "λ_0 = 3" 3.0 r.eigenvalues.(0) ;
    Alcotest.(check (float 1e-10)) "λ_1 = 1" 1.0 r.eigenvalues.(1) ;
    Alcotest.(check bool) "converged" true r.converged


let test_symmetric_3x3 () =
  (* Known eigenvalues: 3, 2, 1 *)
  let m = [| [| 2.0; -1.0; 0.0 |]; [| -1.0; 2.0; -1.0 |]; [| 0.0; -1.0; 2.0 |] |] in
  let r = Eig.jacobi_sym ~matrix:m () in
  let expected = [| 2.0 +. sqrt 2.0; 2.0; 2.0 -. sqrt 2.0 |] in
    Array.iteri
      (fun i exp -> Alcotest.(check (float 1e-8)) (Printf.sprintf "λ_%d" i) exp r.eigenvalues.(i))
      expected


let test_av_equals_lambda_v () =
  (* For random symmetric matrix, ensure A·v_k = λ_k·v_k *)
  let m = [| [| 5.0; 1.0; 2.0 |]; [| 1.0; 4.0; 0.0 |]; [| 2.0; 0.0; 3.0 |] |] in
  let r = Eig.jacobi_sym ~matrix:m () in
  let n = Array.length r.eigenvalues in
    for k = 0 to n - 1 do
      for i = 0 to n - 1 do
        let av = ref 0.0 in
          for j = 0 to n - 1 do
            av := !av +. (m.(i).(j) *. r.eigenvectors.(j).(k))
          done ;
          let lv = r.eigenvalues.(k) *. r.eigenvectors.(i).(k) in
            Alcotest.(check (float 1e-8)) (Printf.sprintf "(Av)_%d = λ_%d·v_%d_%d" i k k i) lv !av
      done
    done


let suite =
  [
    Alcotest.test_case "diagonal_2x2" `Quick test_diagonal_2x2;
    Alcotest.test_case "symmetric_3x3" `Quick test_symmetric_3x3;
    Alcotest.test_case "av_equals_lambda_v" `Quick test_av_equals_lambda_v;
  ]
