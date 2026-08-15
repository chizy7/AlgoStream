open Algostream_risk_management

let cb_config =
  {
    Circuit_breaker.max_drawdown = 0.20;
    max_daily_loss = 0.05;
    max_leverage = 3.0;
    vol_spike_ratio = 5.0;
    cooldown_ns = 10_000_000_000L;
  }


let test_end_to_end_snapshot () =
  let limits = Risk_limits.default in
  let m = Monitor.create ~limits ~circuit_config:cb_config ~initial_equity:100_000.0 () in
  let portfolio =
    Helpers.portfolio_with_positions ~nav:100_000.0
      ~positions:[ ("BTCUSDT", 10.0, 1000.0); ("ETHUSDT", 20.0, 500.0) ]
      () in
  let returns = Helpers.normal_returns ~n:500 ~mean:0.0 ~sd:0.02 ~seed:21 in
  let _ = Monitor.update m ~portfolio ~returns ~ts_ns:1_000_000L () in
  let snap = Monitor.update m ~portfolio ~returns ~ts_ns:2_000_000L () in
    Alcotest.(check bool) "snap has positive var" true (snap.var_pct > 0.0) ;
    Alcotest.(check bool) "ES > VaR" true (snap.expected_shortfall_pct > snap.var_pct) ;
    Alcotest.(check int) "2 positions" 2 snap.n_positions ;
    Alcotest.(check bool) "ready after >=2 updates" true snap.ready


let test_snapshot_atomic_returns_published () =
  let limits = Risk_limits.default in
  let m = Monitor.create ~limits ~circuit_config:cb_config ~initial_equity:100_000.0 () in
  let portfolio = Helpers.portfolio_with_positions ~nav:100_000.0 ~positions:[] () in
  let returns = Helpers.normal_returns ~n:100 ~mean:0.0 ~sd:0.01 ~seed:22 in
  let snap = Monitor.update m ~portfolio ~returns ~ts_ns:1L () in
  let from_atomic = Atomic.get (Monitor.snapshot_atomic m) in
    Alcotest.(check (float 1e-12)) "var matches" snap.var_pct from_atomic.var_pct


let test_correlation_breakdown_aggregated () =
  let limits = Risk_limits.default in
  let m = Monitor.create ~limits ~circuit_config:cb_config ~initial_equity:100_000.0 () in
  let portfolio = Helpers.portfolio_with_positions ~nav:100_000.0 ~positions:[] () in
  let returns = Helpers.normal_returns ~n:100 ~mean:0.0 ~sd:0.01 ~seed:23 in
  (* Feed a steady stable correlation; status should be Stable *)
  let snap = ref Risk_snapshot.empty in
    for i = 1 to 200 do
      snap :=
        Monitor.update m ~portfolio ~returns
          ~correlation_updates:[ ("BTC", "ETH", 0.85) ]
          ~ts_ns:(Int64.of_int (i * 1_000_000))
          ()
    done ;
    Alcotest.(check bool)
      "stable corr → Stable status" true
      (match !snap.correlation_status with Correlation_breakdown.Stable -> true | _ -> false)


let test_stats_track_updates () =
  let limits = Risk_limits.default in
  let m = Monitor.create ~limits ~circuit_config:cb_config ~initial_equity:100_000.0 () in
  let portfolio = Helpers.portfolio_with_positions ~nav:100_000.0 ~positions:[] () in
  let returns = Helpers.normal_returns ~n:100 ~mean:0.0 ~sd:0.01 ~seed:24 in
  let _ = Monitor.update m ~portfolio ~returns ~ts_ns:1L () in
  let _ = Monitor.update m ~portfolio ~returns ~ts_ns:2L () in
  let s = Monitor.stats m in
    Alcotest.(check int) "n_updates = 2" 2 s.n_updates


let suite =
  [
    Alcotest.test_case "end_to_end_snapshot" `Quick test_end_to_end_snapshot;
    Alcotest.test_case "snapshot_atomic_returns_published" `Quick
      test_snapshot_atomic_returns_published;
    Alcotest.test_case "correlation_breakdown_aggregated" `Quick
      test_correlation_breakdown_aggregated;
    Alcotest.test_case "stats_track_updates" `Quick test_stats_track_updates;
  ]
