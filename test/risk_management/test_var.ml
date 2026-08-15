open Algostream_risk_management

let test_parametric_normal_known () =
  (* mean=0, sigma=0.02, conf=0.95, NAV=100k. z(0.05) ≈ -1.645; VaR ≈ -(0 + 0.02 * -1.645) = 0.0329
     → $3290 *)
  let returns = Helpers.normal_returns ~n:1000 ~mean:0.0 ~sd:0.02 ~seed:11 in
  let r =
    Var.compute ~method_:Var.Parametric_normal ~returns ~portfolio_value:100_000.0 ~confidence:0.95
      ~horizon_days:1 in
    Alcotest.(check (float 0.01))
      (Printf.sprintf "VaR pct ~ 0.033 (got %g)" r.var_pct)
      0.033 r.var_pct ;
    Alcotest.(check string) "method = parametric_normal" "parametric_normal" r.method_used


let test_historical_returns_quantile () =
  (* For a symmetric distribution the historical quantile should be close to parametric *)
  let returns = Helpers.normal_returns ~n:5000 ~mean:0.0 ~sd:0.02 ~seed:12 in
  let r =
    Var.compute ~method_:Var.Historical ~returns ~portfolio_value:100_000.0 ~confidence:0.95
      ~horizon_days:1 in
    Alcotest.(check bool)
      (Printf.sprintf "historical VaR in [0.025, 0.045], got %g" r.var_pct)
      true
      (r.var_pct > 0.025 && r.var_pct < 0.045) ;
    Alcotest.(check string) "method = historical" "historical" r.method_used


let test_cornish_fisher_normal_returns () =
  (* For normal returns skew ≈ 0, excess kurtosis ≈ 0; CF should be close to parametric *)
  let returns = Helpers.normal_returns ~n:2000 ~mean:0.0 ~sd:0.02 ~seed:13 in
  let p =
    Var.compute ~method_:Var.Parametric_normal ~returns ~portfolio_value:100_000.0 ~confidence:0.95
      ~horizon_days:1 in
  let cf =
    Var.compute ~method_:Var.Cornish_fisher ~returns ~portfolio_value:100_000.0 ~confidence:0.95
      ~horizon_days:1 in
    Alcotest.(check bool)
      (Printf.sprintf "CF ≈ parametric for normal returns (p=%g cf=%g)" p.var_pct cf.var_pct)
      true
      (abs_float (cf.var_pct -. p.var_pct) < 0.005)


let test_cornish_fisher_left_skewed () =
  (* Inject heavy left tail: append large negative outliers *)
  let base = Helpers.normal_returns ~n:1000 ~mean:0.0 ~sd:0.01 ~seed:14 in
  let outliers = Array.make 30 (-0.08) in
  let returns = Array.append base outliers in
  let p =
    Var.compute ~method_:Var.Parametric_normal ~returns ~portfolio_value:100_000.0 ~confidence:0.95
      ~horizon_days:1 in
  let cf =
    Var.compute ~method_:Var.Cornish_fisher ~returns ~portfolio_value:100_000.0 ~confidence:0.95
      ~horizon_days:1 in
    (* Left skew + heavy tails → CF VaR should exceed parametric *)
    Alcotest.(check bool)
      (Printf.sprintf "CF VaR (%g) > parametric VaR (%g) on left-skewed data" cf.var_pct p.var_pct)
      true (cf.var_pct > p.var_pct)


let test_es_exceeds_var () =
  let returns = Helpers.normal_returns ~n:2000 ~mean:0.0 ~sd:0.02 ~seed:15 in
  let r =
    Var.compute ~method_:Var.Parametric_normal ~returns ~portfolio_value:100_000.0 ~confidence:0.95
      ~horizon_days:1 in
    Alcotest.(check bool) "ES > VaR" true (r.expected_shortfall_pct > r.var_pct)


let test_horizon_scaling () =
  let returns = Helpers.normal_returns ~n:2000 ~mean:0.0 ~sd:0.02 ~seed:16 in
  let one_day =
    Var.compute ~method_:Var.Parametric_normal ~returns ~portfolio_value:100_000.0 ~confidence:0.95
      ~horizon_days:1 in
  let ten_day =
    Var.compute ~method_:Var.Parametric_normal ~returns ~portfolio_value:100_000.0 ~confidence:0.95
      ~horizon_days:10 in
  let expected_ratio = sqrt 10.0 in
  let actual_ratio = ten_day.var_pct /. one_day.var_pct in
    Alcotest.(check (float 1e-6)) "10-day VaR = sqrt(10) × 1-day VaR" expected_ratio actual_ratio


let suite =
  [
    Alcotest.test_case "parametric_normal_known" `Quick test_parametric_normal_known;
    Alcotest.test_case "historical_returns_quantile" `Quick test_historical_returns_quantile;
    Alcotest.test_case "cornish_fisher_normal_returns" `Quick test_cornish_fisher_normal_returns;
    Alcotest.test_case "cornish_fisher_left_skewed" `Quick test_cornish_fisher_left_skewed;
    Alcotest.test_case "es_exceeds_var" `Quick test_es_exceeds_var;
    Alcotest.test_case "horizon_scaling" `Quick test_horizon_scaling;
  ]
