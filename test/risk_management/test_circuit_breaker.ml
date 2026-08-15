open Algostream_risk_management

let default_config =
  {
    Circuit_breaker.max_drawdown = 0.20;
    max_daily_loss = 0.05;
    max_leverage = 3.0;
    vol_spike_ratio = 5.0;
    cooldown_ns = 10_000_000_000L (* 10 seconds *);
  }


let test_drawdown_trips () =
  let cb = Circuit_breaker.create ~config:default_config in
  let state =
    Circuit_breaker.evaluate cb ~drawdown:0.25 ~daily_pnl:0.0 ~leverage:1.0 ~realized_vol:0.02
      ~baseline_vol:0.02 ~ts_ns:0L in
    Alcotest.(check bool)
      "tripped on drawdown" true
      (match state with
      | Circuit_breaker.Tripped { trigger = Drawdown_breach _; _ } -> true
      | _ -> false)


let test_leverage_trips () =
  let cb = Circuit_breaker.create ~config:default_config in
  let state =
    Circuit_breaker.evaluate cb ~drawdown:0.0 ~daily_pnl:0.0 ~leverage:5.0 ~realized_vol:0.02
      ~baseline_vol:0.02 ~ts_ns:0L in
    Alcotest.(check bool)
      "tripped on leverage" true
      (match state with
      | Circuit_breaker.Tripped { trigger = Leverage_breach _; _ } -> true
      | _ -> false)


let test_vol_spike_trips () =
  let cb = Circuit_breaker.create ~config:default_config in
  let state =
    Circuit_breaker.evaluate cb ~drawdown:0.0 ~daily_pnl:0.0 ~leverage:1.0 ~realized_vol:0.30
      ~baseline_vol:0.05 (* ratio = 6, > 5 *)
      ~ts_ns:0L in
    Alcotest.(check bool)
      "tripped on vol spike" true
      (match state with Circuit_breaker.Tripped { trigger = Vol_spike _; _ } -> true | _ -> false)


let test_no_trip_within_limits () =
  let cb = Circuit_breaker.create ~config:default_config in
  let state =
    Circuit_breaker.evaluate cb ~drawdown:0.05 ~daily_pnl:0.01 ~leverage:2.0 ~realized_vol:0.02
      ~baseline_vol:0.02 ~ts_ns:0L in
    Alcotest.(check bool)
      "active when within limits" true
      (match state with Circuit_breaker.Active -> true | _ -> false)


let test_cooldown_transition () =
  let cb = Circuit_breaker.create ~config:default_config in
  let _ =
    Circuit_breaker.evaluate cb ~drawdown:0.25 ~daily_pnl:0.0 ~leverage:1.0 ~realized_vol:0.02
      ~baseline_vol:0.02 ~ts_ns:0L in
  let state_after_cooldown =
    Circuit_breaker.evaluate cb ~drawdown:0.25 ~daily_pnl:0.0 ~leverage:1.0 ~realized_vol:0.02
      ~baseline_vol:0.02 ~ts_ns:20_000_000_000L in
    Alcotest.(check bool)
      "after cooldown → Recovering" true
      (match state_after_cooldown with Circuit_breaker.Recovering _ -> true | _ -> false)


let test_manual_trip () =
  let cb = Circuit_breaker.create ~config:default_config in
    Circuit_breaker.trip_manual cb ~reason:"kill switch" ~ts_ns:0L ;
    Alcotest.(check bool) "is tripped after manual" true (Circuit_breaker.is_tripped cb) ;
    match Circuit_breaker.state cb with
    | Circuit_breaker.Tripped { trigger = Manual "kill switch"; _ } -> ()
    | _ -> Alcotest.fail "expected Tripped (Manual)"


let test_reset () =
  let cb = Circuit_breaker.create ~config:default_config in
    Circuit_breaker.trip_manual cb ~reason:"test" ~ts_ns:0L ;
    Circuit_breaker.reset cb ~ts_ns:1L ;
    Alcotest.(check bool)
      "active after reset" true
      (match Circuit_breaker.state cb with Circuit_breaker.Active -> true | _ -> false)


let suite =
  [
    Alcotest.test_case "drawdown_trips" `Quick test_drawdown_trips;
    Alcotest.test_case "leverage_trips" `Quick test_leverage_trips;
    Alcotest.test_case "vol_spike_trips" `Quick test_vol_spike_trips;
    Alcotest.test_case "no_trip_within_limits" `Quick test_no_trip_within_limits;
    Alcotest.test_case "cooldown_transition" `Quick test_cooldown_transition;
    Alcotest.test_case "manual_trip" `Quick test_manual_trip;
    Alcotest.test_case "reset" `Quick test_reset;
  ]
