open Algostream_order_management

let test_kelly_full_known () =
  (* mean=0.05, variance=0.04 → f* = 1.25 *)
  Alcotest.(check (float 1e-9))
    "f* = 1.25" 1.25
    (Position_sizing.Kelly.full ~mean:0.05 ~variance:0.04)


let test_kelly_zero_variance () =
  Alcotest.(check (float 1e-9))
    "zero variance → 0" 0.0
    (Position_sizing.Kelly.full ~mean:0.05 ~variance:0.0)


let test_kelly_fractional_quarter () =
  let full = Position_sizing.Kelly.full ~mean:0.05 ~variance:0.04 in
  let frac = Position_sizing.Kelly.fractional ~mean:0.05 ~variance:0.04 ~fraction:0.25 in
    Alcotest.(check (float 1e-9)) "fractional = 0.25 × full" (0.25 *. full) frac


let test_kelly_from_winrate () =
  (* p=0.6, b=2 → f* = 0.6 - 0.4/2 = 0.4 *)
  Alcotest.(check (float 1e-9))
    "60% win, 2:1 odds → 0.4" 0.4
    (Position_sizing.Kelly.from_winrate ~win_prob:0.6 ~win_loss_ratio:2.0) ;
  (* Even money, 50/50 → 0 *)
  Alcotest.(check (float 1e-9))
    "no edge → 0" 0.0
    (Position_sizing.Kelly.from_winrate ~win_prob:0.5 ~win_loss_ratio:1.0)


let test_size_position_caps_at_cap_pct () =
  (* kelly_fraction=1.25 capped at 1.0 → all capital in *)
  let shares =
    Position_sizing.Kelly.size_position ~capital:100_000.0 ~kelly_fraction:1.25 ~price:100.0 ()
  in
    Alcotest.(check (float 1e-9)) "1000 shares (100k / 100, capped)" 1000.0 shares


let test_size_position_custom_cap () =
  let shares =
    Position_sizing.Kelly.size_position ~capital:100_000.0 ~kelly_fraction:0.5 ~price:100.0
      ~cap_pct:0.3 () in
    Alcotest.(check (float 1e-9)) "min(0.5, 0.3) × 100k / 100 = 300" 300.0 shares


let test_size_position_negative_fraction () =
  let shares =
    Position_sizing.Kelly.size_position ~capital:100_000.0 ~kelly_fraction:(-0.5) ~price:100.0 ()
  in
    Alcotest.(check (float 1e-9)) "negative → 0" 0.0 shares


let test_volatility_scaling () =
  (* target $10k vol, asset_vol = 0.02 (2% daily), price = $100 position_value = 10000 / 0.02 =
     500_000; shares = 500_000 / 100 = 5000 capped at capital / price = 100_000 / 100 = 1000 *)
  let shares =
    Position_sizing.Volatility_scaling.size ~capital:100_000.0 ~target_vol:10_000.0 ~asset_vol:0.02
      ~price:100.0 in
    Alcotest.(check (float 1e-9)) "capped at capital/price" 1000.0 shares


let test_volatility_scaling_uncapped () =
  (* Large capital → uncapped: 500_000 / 100 = 5000 *)
  let shares =
    Position_sizing.Volatility_scaling.size ~capital:10_000_000.0 ~target_vol:10_000.0
      ~asset_vol:0.02 ~price:100.0 in
    Alcotest.(check (float 1e-9)) "uncapped 5000" 5000.0 shares


let test_atr_size () =
  (* capital=100k, risk_pct=0.01 (1%), atr=$2, price=100 raw = (100_000 * 0.01) / 2 = 500 shares cap
     = capital/price = 1000 → not binding *)
  let shares =
    Position_sizing.Volatility_scaling.atr_size ~capital:100_000.0 ~risk_pct:0.01 ~atr:2.0
      ~price:100.0 in
    Alcotest.(check (float 1e-9)) "500 shares" 500.0 shares


let suite =
  [
    Alcotest.test_case "kelly_full_known" `Quick test_kelly_full_known;
    Alcotest.test_case "kelly_zero_variance" `Quick test_kelly_zero_variance;
    Alcotest.test_case "kelly_fractional_quarter" `Quick test_kelly_fractional_quarter;
    Alcotest.test_case "kelly_from_winrate" `Quick test_kelly_from_winrate;
    Alcotest.test_case "size_position_caps_at_cap_pct" `Quick test_size_position_caps_at_cap_pct;
    Alcotest.test_case "size_position_custom_cap" `Quick test_size_position_custom_cap;
    Alcotest.test_case "size_position_negative_fraction" `Quick test_size_position_negative_fraction;
    Alcotest.test_case "volatility_scaling" `Quick test_volatility_scaling;
    Alcotest.test_case "volatility_scaling_uncapped" `Quick test_volatility_scaling_uncapped;
    Alcotest.test_case "atr_size" `Quick test_atr_size;
  ]
