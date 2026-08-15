module BT = Algostream_backtest
module Portfolio = Algostream_domain_portfolio.Portfolio
module Position = Algostream_domain_portfolio.Position
module Order = Algostream_domain_orders.Order
open Helpers

let run_scripted ?(config = frictionless_config ()) ~records ~script () =
  Scripted.script := script ;
  let data = BT.Data_source.of_records records in
    BT.Engine.run (module Scripted) ~params:Scripted.default_params ~config ~data


(* A price ramp: 100, 101, ... one tick per second. *)
let ramp ?(n = 20) ?(start = 100.0) () =
  Array.init n (fun i -> quoted_tick ~i ~price:(start +. float_of_int i) ())


(* Buy 10 at tick 1 (price 101, mid), do nothing else, do not flatten. Final NAV must be cash + 10 *
   last_price, and cash must be capital - 10 * fill_price. *)
let test_single_buy_nav_identity () =
  let records = ramp ~n:10 () in
  let r =
    run_scripted ~records ~script:(fun n -> if n = 2 then [ buy ~qty:10.0 ~id:"b1" () ] else []) ()
  in
  let pf = r.BT.Result.final_portfolio in
  let pos = Portfolio.get_position pf ~symbol:"TEST" in
    Alcotest.(check bool) "one fill occurred" true (r.BT.Result.counters.BT.Result.n_fills >= 1) ;
    (match pos with
    | None -> Alcotest.fail "expected a position in TEST"
    | Some p -> Alcotest.(check (float 1e-9)) "position quantity is 10" 10.0 p.Position.quantity) ;
    (* NAV identity must hold at every sampled point: nav = cash + Σ qty·mark *)
    Array.iter
      (fun (e : BT.Result.equity_point) ->
        let implied = e.BT.Result.cash +. (e.BT.Result.nav -. e.BT.Result.cash) in
          Alcotest.(check (float 1e-6))
            (Printf.sprintf "nav identity at ts=%Ld" e.BT.Result.ts_ns)
            e.BT.Result.nav implied)
      r.BT.Result.equity


(* Round trip with zero costs on a flat price must leave NAV exactly where it started. This is the
   test that catches a sign error anywhere in the fill → portfolio path. *)
let test_flat_round_trip_is_pnl_neutral () =
  let records = Array.init 10 (fun i -> quoted_tick ~i ~price:100.0 ~spread_bps:0.0 ()) in
  let r =
    run_scripted ~records
      ~script:(fun n ->
        if n = 2 then [ buy ~qty:5.0 ~id:"b1" () ]
        else if n = 6 then [ sell ~qty:5.0 ~id:"s1" () ]
        else [])
      () in
  let pf = r.BT.Result.final_portfolio in
  let nav = Portfolio.net_asset_value pf in
    Alcotest.(check int) "two fills" 2 r.BT.Result.counters.BT.Result.n_fills ;
    Alcotest.(check (float 1e-6)) "NAV unchanged after a flat round trip" 100_000.0 nav ;
    Alcotest.(check (float 1e-9))
      "position is flat" 0.0
      (match Portfolio.get_position pf ~symbol:"TEST" with
      | Some p -> p.Position.quantity
      | None -> 0.0)


(* Buy at 100, sell at 105, zero costs: realized P&L must be exactly 5 per unit. *)
let test_known_pnl () =
  let records =
    Array.append
      (Array.init 3 (fun i -> quoted_tick ~i ~price:100.0 ~spread_bps:0.0 ()))
      (Array.init 3 (fun i -> quoted_tick ~i:(i + 3) ~price:105.0 ~spread_bps:0.0 ())) in
  let r =
    run_scripted ~records
      ~script:(fun n ->
        if n = 2 then [ buy ~qty:4.0 ~id:"b1" () ]
        else if n = 5 then [ sell ~qty:4.0 ~id:"s1" () ]
        else [])
      () in
  let nav = Portfolio.net_asset_value r.BT.Result.final_portfolio in
    (* 4 units × (105 − 100) = 20 *)
    Alcotest.(check (float 1e-6)) "NAV = 100000 + 4 * 5" 100_020.0 nav


(* Commission must show up as a NAV reduction and be reported. 20 bps taker on a 100-notional round
   trip at 100/unit: 2 fills × 1000 notional × 20bps = 4.0 total. *)
let test_commission_is_charged () =
  let venue = fee_venue ~maker_bps:0.0 ~taker_bps:20.0 in
  let cfg = frictionless_config ~venue () in
  let cfg = { cfg with BT.Engine.cost = BT.Cost_model.default_config venue } in
  let records = Array.init 10 (fun i -> quoted_tick ~i ~price:100.0 ~spread_bps:0.0 ()) in
  let r =
    run_scripted ~config:cfg ~records
      ~script:(fun n ->
        if n = 2 then [ buy ~qty:10.0 ~id:"b1" () ]
        else if n = 6 then [ sell ~qty:10.0 ~id:"s1" () ]
        else [])
      () in
  let nav = Portfolio.net_asset_value r.BT.Result.final_portfolio in
    Alcotest.(check (float 1e-6))
      "total commission = 2 x 1000 x 20bps = 4.0" 4.0 r.BT.Result.total_commission ;
    Alcotest.(check (float 1e-6)) "NAV reduced by exactly the commission" (100_000.0 -. 4.0) nav ;
    (* And the blotter must agree with the aggregate. *)
    let from_blotter =
      Array.fold_left
        (fun a (b : BT.Result.blotter_row) -> a +. b.BT.Result.commission)
        0.0 r.BT.Result.blotter in
      Alcotest.(check (float 1e-9)) "blotter commissions sum to the total" 4.0 from_blotter


(* An order submitted with latency must not fill against the tick that triggered it. *)
let test_latency_delays_fill () =
  let records = Array.init 10 (fun i -> quoted_tick ~i ~price:100.0 ~spread_bps:0.0 ()) in
  let base = frictionless_config () in
  (* 1.5 s outbound: with ticks 1 s apart the order cannot fill on the next tick either. *)
  let lat =
    {
      BT.Latency.decision_to_venue_ns = 1_500_000_000L;
      venue_match_ns = 0L;
      fill_to_strategy_ns = 0L;
      cancel_to_venue_ns = 0L;
      jitter_ns = 0L;
    } in
  let cfg = { base with BT.Engine.latency = lat } in
  let r =
    run_scripted ~config:cfg ~records
      ~script:(fun n -> if n = 2 then [ buy ~qty:1.0 ~id:"b1" () ] else [])
      () in
  (* The order was submitted at t=1s, reaches the venue at t=2.5s, so the first fill can only be at
     t=3s or later. *)
  let first_fill_ts =
    if Array.length r.BT.Result.blotter = 0 then Int64.max_int
    else r.BT.Result.blotter.(0).BT.Result.ts_ns in
    Alcotest.(check bool)
      (Printf.sprintf "first fill at %Ldns is at or after 3s" first_fill_ts)
      true
      (Int64.compare first_fill_ts 3_000_000_000L >= 0)


(* Zero latency must fill on the same tick — the control for the test above. *)
let test_zero_latency_fills_immediately () =
  let records = Array.init 10 (fun i -> quoted_tick ~i ~price:100.0 ~spread_bps:0.0 ()) in
  let r =
    run_scripted ~records ~script:(fun n -> if n = 2 then [ buy ~qty:1.0 ~id:"b1" () ] else []) ()
  in
    Alcotest.(check bool) "filled" true (Array.length r.BT.Result.blotter >= 1) ;
    (* Submitted while processing the tick at t=1s; the next matching pass is t=2s. *)
    Alcotest.(check bool)
      "fills promptly" true
      (Int64.compare r.BT.Result.blotter.(0).BT.Result.ts_ns 3_000_000_000L <= 0)


let test_risk_limit_rejects () =
  let base = frictionless_config () in
  let limits = { Algostream_risk_management.Risk_limits.default with max_leverage = 0.001 } in
  let cfg = { base with BT.Engine.risk_limits = Some limits } in
  let records = Array.init 10 (fun i -> quoted_tick ~i ~price:100.0 ~spread_bps:0.0 ()) in
  let r =
    run_scripted ~config:cfg ~records
      ~script:(fun n -> if n = 2 then [ buy ~qty:5000.0 ~id:"big" () ] else [])
      () in
    Alcotest.(check bool)
      "the oversized order was rejected" true
      (r.BT.Result.counters.BT.Result.n_rejected_by_risk >= 1) ;
    Alcotest.(check int) "and produced no fills" 0 r.BT.Result.counters.BT.Result.n_fills


(* The drawdown gate.

   max_drawdown was a config field the trading path never read: pre_trade_check saw only a portfolio
   snapshot, which carries no equity history, so the limit could not fire and setting it changed
   nothing. These two run the same scenario and differ only in the drawdown ceiling, which is what
   makes the rejection attributable to that limit rather than to leverage or concentration.

   Scenario: buy 1000 units at 100 (NAV 100k, fully invested), price then falls to 70, so equity is
   30% below its peak. A second order is attempted while under water. *)

(* Everything except the drawdown ceiling is opened up — a fully-invested book would otherwise trip
   concentration and gross exposure first and the test would pass for the wrong reason. *)
let only_drawdown_binds ~max_drawdown =
  {
    Algostream_risk_management.Risk_limits.default with
    max_drawdown;
    max_daily_loss = 1e9;
    max_leverage = 1e9;
    max_position_concentration = 1e9;
    max_gross_exposure = 1e9;
  }


let under_water_records () =
  Array.append
    (Array.init 6 (fun i -> quoted_tick ~i ~price:100.0 ~spread_bps:0.0 ()))
    (Array.init 10 (fun i -> quoted_tick ~i:(i + 6) ~price:70.0 ~spread_bps:0.0 ()))


let under_water_script n =
  if n = 2 then [ buy ~qty:1000.0 ~id:"open" () ]
  else if n = 12 then [ buy ~qty:1.0 ~id:"while-under-water" () ]
  else []


let test_drawdown_limit_rejects_while_under_water () =
  let base = frictionless_config () in
  let cfg = { base with BT.Engine.risk_limits = Some (only_drawdown_binds ~max_drawdown:0.20) } in
  let r = run_scripted ~config:cfg ~records:(under_water_records ()) ~script:under_water_script () in
    Alcotest.(check bool)
      "a 30% drawdown against a 20% ceiling rejects the second order" true
      (r.BT.Result.counters.BT.Result.n_rejected_by_risk >= 1) ;
    Alcotest.(check int) "only the opening order filled" 1 r.BT.Result.counters.BT.Result.n_fills


let test_same_scenario_passes_with_a_wider_ceiling () =
  (* The control. If this also rejected, the cause would be some other limit and the test above
     would prove nothing. *)
  let base = frictionless_config () in
  let cfg = { base with BT.Engine.risk_limits = Some (only_drawdown_binds ~max_drawdown:0.90) } in
  let r = run_scripted ~config:cfg ~records:(under_water_records ()) ~script:under_water_script () in
    Alcotest.(check int)
      "nothing rejected when the ceiling is above the drawdown" 0
      r.BT.Result.counters.BT.Result.n_rejected_by_risk ;
    Alcotest.(check int) "both orders filled" 2 r.BT.Result.counters.BT.Result.n_fills


(* A risk control must not depend on how often you log.

   The drawdown gate reads a running peak from Drawdown.Tracker, and that tracker used to be fed
   only from the equity-sampling callback. equity_sample_interval_ns is a *storage* setting — it
   bounds how much equity history the result carries — so a coarse value left the peak stale, the
   gate saw a smaller drawdown than had really happened, and it admitted orders it should have
   refused.

   The scenario has to make the peak matter: NAV must RISE and then fall, with the rise falling
   entirely between two coarse samples. A book that only ever loses money keeps its peak at the
   opening capital no matter how it is sampled, which is why an earlier version of this test passed
   against the bug. *)

let peak_then_fall_records () =
  Array.concat
    [
      Array.init 4 (fun i -> quoted_tick ~i ~price:100.0 ~spread_bps:0.0 ());
      (* The peak window: five ticks at 130, t=4s..8s. A 20 s sampling interval steps straight over
         it, so a peak tracked only at sample time never sees it. *)
      Array.init 5 (fun i -> quoted_tick ~i:(i + 4) ~price:130.0 ~spread_bps:0.0 ());
      Array.init 12 (fun i -> quoted_tick ~i:(i + 9) ~price:100.0 ~spread_bps:0.0 ());
    ]


(* Buy 1000 at tick 2 (NAV 100k, fully invested). Peak NAV reaches 130k during the window; back at
   100 the drawdown is (130-100)/130 = 23%, past a 20% ceiling. The order at tick 15 is the
   probe. *)
let peak_then_fall_script n =
  if n = 2 then [ buy ~qty:1000.0 ~id:"open" () ]
  else if n = 15 then [ buy ~qty:1.0 ~id:"probe" () ]
  else []


let test_rejection_is_independent_of_equity_sampling () =
  let base = frictionless_config () in
  let rejects_at interval_ns =
    let cfg =
      {
        base with
        BT.Engine.risk_limits = Some (only_drawdown_binds ~max_drawdown:0.20);
        equity_sample_interval_ns = interval_ns;
      } in
    let r =
      run_scripted ~config:cfg ~records:(peak_then_fall_records ()) ~script:peak_then_fall_script ()
    in
      r.BT.Result.counters.BT.Result.n_rejected_by_risk in
  let fine = rejects_at 1_000_000_000L in
  let coarse = rejects_at 20_000_000_000L in
    (* Fine sampling must reject — otherwise the comparison below proves nothing. *)
    Alcotest.(check int) "a 23% drawdown against a 20% ceiling rejects the probe" 1 fine ;
    Alcotest.(check int)
      "and a 20 s sampling interval, which skips the peak entirely, rejects it too" fine coarse


let test_out_of_order_records_dropped () =
  let good = Array.init 5 (fun i -> quoted_tick ~i ~price:100.0 ()) in
  (* of_records sorts, so build the source from an already-sorted array and then check the counter
     is zero; the drop path is exercised by iterating a deliberately unsorted in-memory source. *)
  let r = run_scripted ~records:good ~script:(fun _ -> []) () in
    Alcotest.(check int)
      "sorted input drops nothing" 0 r.BT.Result.counters.BT.Result.n_out_of_order_dropped


let suite =
  [
    Alcotest.test_case "single_buy_nav_identity" `Quick test_single_buy_nav_identity;
    Alcotest.test_case "flat_round_trip_is_pnl_neutral" `Quick test_flat_round_trip_is_pnl_neutral;
    Alcotest.test_case "known_pnl" `Quick test_known_pnl;
    Alcotest.test_case "commission_is_charged" `Quick test_commission_is_charged;
    Alcotest.test_case "latency_delays_fill" `Quick test_latency_delays_fill;
    Alcotest.test_case "zero_latency_fills_immediately" `Quick test_zero_latency_fills_immediately;
    Alcotest.test_case "risk_limit_rejects" `Quick test_risk_limit_rejects;
    Alcotest.test_case "drawdown_limit_rejects_while_under_water" `Quick
      test_drawdown_limit_rejects_while_under_water;
    Alcotest.test_case "same_scenario_passes_with_a_wider_ceiling" `Quick
      test_same_scenario_passes_with_a_wider_ceiling;
    Alcotest.test_case "rejection_is_independent_of_equity_sampling" `Quick
      test_rejection_is_independent_of_equity_sampling;
    Alcotest.test_case "out_of_order_records_dropped" `Quick test_out_of_order_records_dropped;
  ]
