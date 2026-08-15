open Algostream_advanced_models

let approx_eq ~tol a b = abs_float (a -. b) < tol

let test_erf_table () =
  Alcotest.(check (float 1e-5)) "erf(0) = 0" 0.0 (Special.erf 0.0) ;
  Alcotest.(check (float 1e-5)) "erf(1.0) ≈ 0.8427" 0.8427007929 (Special.erf 1.0) ;
  Alcotest.(check bool)
    "erf is odd" true
    (approx_eq ~tol:1e-5 (Special.erf (-0.5)) (-.Special.erf 0.5))


let test_normal_cdf () =
  Alcotest.(check (float 1e-4)) "Φ(0) = 0.5" 0.5 (Special.normal_cdf ~x:0.0) ;
  Alcotest.(check (float 1e-4)) "Φ(1.96) ≈ 0.975" 0.975 (Special.normal_cdf ~x:1.96) ;
  Alcotest.(check (float 1e-4)) "Φ(-1.96) ≈ 0.025" 0.025 (Special.normal_cdf ~x:(-1.96))


let test_normal_quantile_roundtrip () =
  let xs = [ -2.0; -1.0; 0.0; 1.0; 2.0 ] in
    List.iter
      (fun x ->
        let p = Special.normal_cdf ~x in
        let xr = Special.normal_quantile ~p in
          Alcotest.(check (float 1e-3)) (Printf.sprintf "quantile(cdf(%g)) = %g" x x) x xr)
      xs


let test_log_gamma_table () =
  Alcotest.(check (float 1e-6)) "log_gamma(1) = 0" 0.0 (Special.log_gamma 1.0) ;
  Alcotest.(check (float 1e-6)) "log_gamma(2) = 0" 0.0 (Special.log_gamma 2.0) ;
  Alcotest.(check (float 1e-6)) "log_gamma(5) = log(24)" (log 24.0) (Special.log_gamma 5.0)


let test_incomplete_gamma () =
  (* P(1, 1) = 1 - e^-1 ≈ 0.6321 *)
  Alcotest.(check (float 1e-4))
    "P(1, 1) = 1 - 1/e"
    (1.0 -. exp (-1.0))
    (Special.incomplete_gamma_p ~s:1.0 ~x:1.0)


let test_regularized_beta () =
  (* I_x(a, a) at x=0.5 should be 0.5 by symmetry *)
  Alcotest.(check (float 1e-4))
    "I_0.5(5, 5) = 0.5" 0.5
    (Special.regularized_beta ~x:0.5 ~a:5.0 ~b:5.0)


let suite =
  [
    Alcotest.test_case "erf_table" `Quick test_erf_table;
    Alcotest.test_case "normal_cdf" `Quick test_normal_cdf;
    Alcotest.test_case "normal_quantile_roundtrip" `Quick test_normal_quantile_roundtrip;
    Alcotest.test_case "log_gamma_table" `Quick test_log_gamma_table;
    Alcotest.test_case "incomplete_gamma" `Quick test_incomplete_gamma;
    Alcotest.test_case "regularized_beta" `Quick test_regularized_beta;
  ]
