module R = Algostream_analytics.Regime
module C = Algostream_analytics.Config

let test_starts_calm () =
  let d = R.create C.default in
    Alcotest.(check bool) "initial calm" true (R.equal (R.current d) R.Calm)


let test_crisis_on_drawdown () =
  let cfg = { C.default with regime_to_crisis_dwell_ns = 0L; regime_to_crisis_min_ticks = 1 } in
  let d = R.create cfg in
  let _ =
    R.update d ~ts_ns:0L ~ewma_vol:0.01 ~vol_band_median:0.01 ~drawdown_from_peak:0.10
      ~return_run_length:0 ~return_run_sign:0 in
  let r =
    R.update d ~ts_ns:1L ~ewma_vol:0.01 ~vol_band_median:0.01 ~drawdown_from_peak:0.10
      ~return_run_length:0 ~return_run_sign:0 in
    Alcotest.(check bool) "drawdown >= threshold triggers crisis" true (R.equal r R.Crisis)


let test_volatile_band () =
  let cfg =
    { C.default with regime_calm_to_volatile_dwell_ns = 0L; regime_calm_to_volatile_min_ticks = 1 }
  in
  let d = R.create cfg in
  let _ =
    R.update d ~ts_ns:0L ~ewma_vol:1.0 ~vol_band_median:0.1 ~drawdown_from_peak:0.0
      ~return_run_length:0 ~return_run_sign:0 in
  let r =
    R.update d ~ts_ns:1L ~ewma_vol:1.0 ~vol_band_median:0.1 ~drawdown_from_peak:0.0
      ~return_run_length:0 ~return_run_sign:0 in
    Alcotest.(check bool) "high vol band triggers volatile" true (R.equal r R.Volatile)


let test_dwell_required () =
  (* with a non-zero dwell, a single tick is not enough to transition. *)
  let cfg =
    {
      C.default with
      regime_calm_to_volatile_dwell_ns = 1_000_000_000L;
      regime_calm_to_volatile_min_ticks = 50;
    } in
  let d = R.create cfg in
  let r =
    R.update d ~ts_ns:0L ~ewma_vol:1.0 ~vol_band_median:0.1 ~drawdown_from_peak:0.0
      ~return_run_length:0 ~return_run_sign:0 in
    Alcotest.(check bool) "no transition with insufficient dwell" true (R.equal r R.Calm)


let suite =
  [
    Alcotest.test_case "starts_calm" `Quick test_starts_calm;
    Alcotest.test_case "crisis_on_drawdown" `Quick test_crisis_on_drawdown;
    Alcotest.test_case "volatile_band" `Quick test_volatile_band;
    Alcotest.test_case "dwell_required" `Quick test_dwell_required;
  ]
