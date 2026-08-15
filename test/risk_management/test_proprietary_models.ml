open Algostream_risk_management

let test_low_level_all_zero () =
  let s =
    Proprietary_models.compute_score ~var_pct:0.0 ~max_var_pct:0.05 ~current_drawdown:0.0
      ~max_drawdown:0.20 ~leverage:0.0 ~max_leverage:3.0
      ~correlation_status:Correlation_breakdown.Stable ~circuit_state:Circuit_breaker.Active
      ~realized_vol:0.02 ~baseline_vol:0.02 () in
    Alcotest.(check (float 1e-9)) "composite = 0" 0.0 s.composite ;
    Alcotest.(check bool)
      "level = Low" true
      (match s.level with Proprietary_models.Low -> true | _ -> false) ;
    Alcotest.(check bool)
      "vol regime = Normal (ratio=1)" true
      (match s.vol_regime with Proprietary_models.Normal -> true | _ -> false)


let test_critical_when_all_max () =
  let s =
    Proprietary_models.compute_score ~var_pct:0.05 ~max_var_pct:0.05 ~current_drawdown:0.20
      ~max_drawdown:0.20 ~leverage:3.0 ~max_leverage:3.0
      ~correlation_status:(Correlation_breakdown.Sign_flipped (-0.8))
      ~circuit_state:
        (Circuit_breaker.Tripped
           {
             trigger = Circuit_breaker.Drawdown_breach { current = 0.25; limit = 0.20 };
             tripped_at_ns = 0L;
           })
      ~realized_vol:0.10 ~baseline_vol:0.02 () in
    Alcotest.(check (float 1e-9)) "composite = 1.0" 1.0 s.composite ;
    Alcotest.(check bool)
      "level = Critical" true
      (match s.level with Proprietary_models.Critical -> true | _ -> false) ;
    Alcotest.(check bool)
      "vol regime = Stressed (5x)" true
      (match s.vol_regime with Proprietary_models.Stressed -> true | _ -> false)


let test_moderate_partial_breach () =
  let s =
    Proprietary_models.compute_score ~var_pct:0.025 ~max_var_pct:0.05 ~current_drawdown:0.10
      ~max_drawdown:0.20 ~leverage:1.0 ~max_leverage:3.0
      ~correlation_status:Correlation_breakdown.Stable ~circuit_state:Circuit_breaker.Active
      ~realized_vol:0.02 ~baseline_vol:0.02 () in
    Alcotest.(check bool)
      (Printf.sprintf "composite in [0.1, 0.4] (got %g)" s.composite)
      true
      (s.composite >= 0.1 && s.composite < 0.4)


let test_vol_regime_classification () =
  let calm = Proprietary_models.classify_vol_regime ~realized_vol:0.005 ~baseline_vol:0.02 in
  let normal = Proprietary_models.classify_vol_regime ~realized_vol:0.02 ~baseline_vol:0.02 in
  let elevated = Proprietary_models.classify_vol_regime ~realized_vol:0.04 ~baseline_vol:0.02 in
  let stressed = Proprietary_models.classify_vol_regime ~realized_vol:0.10 ~baseline_vol:0.02 in
    Alcotest.(check bool)
      "calm" true
      (match calm with Proprietary_models.Calm -> true | _ -> false) ;
    Alcotest.(check bool)
      "normal" true
      (match normal with Proprietary_models.Normal -> true | _ -> false) ;
    Alcotest.(check bool)
      "elevated" true
      (match elevated with Proprietary_models.Elevated -> true | _ -> false) ;
    Alcotest.(check bool)
      "stressed" true
      (match stressed with Proprietary_models.Stressed -> true | _ -> false)


let test_correlation_severity () =
  let make corr_status =
    Proprietary_models.compute_score ~var_pct:0.0 ~max_var_pct:0.05 ~current_drawdown:0.0
      ~max_drawdown:0.20 ~leverage:0.0 ~max_leverage:3.0 ~correlation_status:corr_status
      ~circuit_state:Circuit_breaker.Active ~realized_vol:0.02 ~baseline_vol:0.02 () in
  let stable = make Correlation_breakdown.Stable in
  let weak = make (Correlation_breakdown.Weakening 0.5) in
  let broken = make (Correlation_breakdown.Broken_down 0.3) in
  let flipped = make (Correlation_breakdown.Sign_flipped (-0.5)) in
    Alcotest.(check bool) "stable < weak" true (stable.composite < weak.composite) ;
    Alcotest.(check bool) "weak < broken" true (weak.composite < broken.composite) ;
    Alcotest.(check bool) "broken < flipped" true (broken.composite < flipped.composite)


let test_recovering_half_weight () =
  let active =
    Proprietary_models.compute_score ~var_pct:0.0 ~max_var_pct:0.05 ~current_drawdown:0.0
      ~max_drawdown:0.20 ~leverage:0.0 ~max_leverage:3.0
      ~correlation_status:Correlation_breakdown.Stable ~circuit_state:Circuit_breaker.Active
      ~realized_vol:0.02 ~baseline_vol:0.02 () in
  let recovering =
    Proprietary_models.compute_score ~var_pct:0.0 ~max_var_pct:0.05 ~current_drawdown:0.0
      ~max_drawdown:0.20 ~leverage:0.0 ~max_leverage:3.0
      ~correlation_status:Correlation_breakdown.Stable
      ~circuit_state:(Circuit_breaker.Recovering { since_ns = 0L })
      ~realized_vol:0.02 ~baseline_vol:0.02 () in
  let tripped =
    Proprietary_models.compute_score ~var_pct:0.0 ~max_var_pct:0.05 ~current_drawdown:0.0
      ~max_drawdown:0.20 ~leverage:0.0 ~max_leverage:3.0
      ~correlation_status:Correlation_breakdown.Stable
      ~circuit_state:
        (Circuit_breaker.Tripped { trigger = Circuit_breaker.Manual "test"; tripped_at_ns = 0L })
      ~realized_vol:0.02 ~baseline_vol:0.02 () in
    Alcotest.(check bool)
      "active < recovering < tripped" true
      (active.composite < recovering.composite && recovering.composite < tripped.composite)


let test_custom_weights () =
  let w =
    {
      Proprietary_models.var = 1.0;
      drawdown = 0.0;
      leverage = 0.0;
      correlation = 0.0;
      circuit = 0.0;
    } in
  let s =
    Proprietary_models.compute_score ~weights:w ~var_pct:0.025 ~max_var_pct:0.05
      ~current_drawdown:0.10 ~max_drawdown:0.20 ~leverage:1.0 ~max_leverage:3.0
      ~correlation_status:Correlation_breakdown.Stable ~circuit_state:Circuit_breaker.Active
      ~realized_vol:0.02 ~baseline_vol:0.02 () in
    Alcotest.(check (float 1e-9)) "composite = var_component (0.5)" 0.5 s.composite


let test_from_snapshot () =
  let limits = { Risk_limits.default with max_var_pct = 0.05; max_drawdown = 0.20 } in
  let snap =
    { Risk_snapshot.empty with var_pct = 0.025; current_drawdown = 0.05; leverage_ratio = 1.5 }
  in
  let score =
    Proprietary_models.from_snapshot ~snapshot:snap ~limits ~realized_vol:0.02 ~baseline_vol:0.02 ()
  in
    Alcotest.(check (float 1e-6)) "var component" 0.5 score.var_component ;
    Alcotest.(check (float 1e-6)) "dd component" 0.25 score.drawdown_component ;
    Alcotest.(check (float 1e-6)) "leverage component" 0.5 score.leverage_component


let suite =
  [
    Alcotest.test_case "low_level_all_zero" `Quick test_low_level_all_zero;
    Alcotest.test_case "critical_when_all_max" `Quick test_critical_when_all_max;
    Alcotest.test_case "moderate_partial_breach" `Quick test_moderate_partial_breach;
    Alcotest.test_case "vol_regime_classification" `Quick test_vol_regime_classification;
    Alcotest.test_case "correlation_severity" `Quick test_correlation_severity;
    Alcotest.test_case "recovering_half_weight" `Quick test_recovering_half_weight;
    Alcotest.test_case "custom_weights" `Quick test_custom_weights;
    Alcotest.test_case "from_snapshot" `Quick test_from_snapshot;
  ]
