open Algostream_advanced_models

let test_normal_table () =
  Alcotest.(check (float 1e-4)) "Φ(0) = 0.5" 0.5 (Distribution.Normal.cdf ~x:0.0) ;
  Alcotest.(check (float 1e-4)) "Φ(1.645) ≈ 0.95" 0.95 (Distribution.Normal.cdf ~x:1.645)


let test_t_table () =
  (* For df=10, P(T <= 2.228) ≈ 0.975 *)
  Alcotest.(check (float 0.005))
    "t_10 CDF at 2.228 ~ 0.975" 0.975
    (Distribution.Student_t.cdf ~x:2.228 ~df:10.0) ;
  (* Symmetric *)
  Alcotest.(check (float 0.005))
    "t_5 CDF at 0 = 0.5" 0.5
    (Distribution.Student_t.cdf ~x:0.0 ~df:5.0)


let test_chi_squared_table () =
  (* P(χ²_1 <= 3.84) ≈ 0.95 *)
  Alcotest.(check (float 0.01))
    "χ²_1 CDF at 3.84 ~ 0.95" 0.95
    (Distribution.Chi_squared.cdf ~x:3.84 ~df:1.0) ;
  (* P(χ²_5 <= 11.07) ≈ 0.95 *)
  Alcotest.(check (float 0.01))
    "χ²_5 CDF at 11.07 ~ 0.95" 0.95
    (Distribution.Chi_squared.cdf ~x:11.07 ~df:5.0)


let test_f_table () =
  (* F(5, 10) CDF at 3.33 ≈ 0.95 *)
  Alcotest.(check (float 0.01))
    "F_{5,10} CDF at 3.33 ~ 0.95" 0.95
    (Distribution.F.cdf ~x:3.33 ~d1:5.0 ~d2:10.0)


let suite =
  [
    Alcotest.test_case "normal_table" `Quick test_normal_table;
    Alcotest.test_case "t_table" `Quick test_t_table;
    Alcotest.test_case "chi_squared_table" `Quick test_chi_squared_table;
    Alcotest.test_case "f_table" `Quick test_f_table;
  ]
