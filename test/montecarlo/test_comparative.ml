(* Paired comparison under common random numbers.

   Two properties matter here and they pull in opposite directions, which is why both are tested:

   1. Identical arms must difference to *exactly* zero. That is the only assertion that proves the
   two arms genuinely shared the market path. If CRN were broken — a consumed generator, an
   execution substream that depends on the arm — the two arms would see different paths and the
   difference would be small but non-zero, which reads like noise rather than like a bug.

   2. Arms that differ only in the *backtest config* must be able to differ in outcome. That is the
   capability the risk-limits experiment needs: risk limits are not strategy parameters, so a
   params-only comparative could not express "same strategy, same market, limits on vs off". *)

module MC = Algostream_montecarlo
module BT = Algostream_backtest
module Strategy = Algostream_strategy.Strategy
module Action = Algostream_strategy.Action
module Event = Algostream_strategy.Event
module Order = Algostream_domain_orders.Order
module Risk_limits = Algostream_risk_management.Risk_limits
module Quantile = Algostream_stochastic.Quantile

(* Scales into a long position and never exits. Chosen deliberately: a buy-and-hold that enters once
   would show no difference under a drawdown gate, because the gate blocks *new* orders rather than
   liquidating. A strategy that keeps adding is the case where refusing to add is what caps the loss
   — which is the mechanism the risk limits actually have. *)
module Accumulator = struct
  let name = "accumulator"

  let version = "1.0"

  type params = { qty_per_add : float }

  let default_params = { qty_per_add = 20.0 }

  let params_of_assoc a =
    match Strategy.require a "qty_per_add" with
    | Ok qty_per_add -> Ok { qty_per_add }
    | Error e -> Error e


  let params_to_assoc p = [ ("qty_per_add", p.qty_per_add) ]

  let param_bounds = [ ("qty_per_add", 1.0, 100.0) ]

  type state = {
    p : params;
    syms : string list;
    mutable n : int;
  }

  let create ~params ~symbols = { p = params; syms = symbols; n = 0 }

  let subscriptions t = List.map (fun s -> Strategy.Symbol s) t.syms

  let on_event t (_ctx : Algostream_strategy.Context.t) (ev : Event.t) =
    match ev with
    | Event.Tick { symbol; _ } ->
      t.n <- t.n + 1 ;
      (* Add every 25th tick. Frequent enough that a gate has many chances to bind, sparse enough
         that the run is not dominated by transaction handling. *)
      if t.n mod 25 = 0 then
        [
          Action.Submit
            {
              Action.symbol;
              side = Algostream_strategy.Side.Buy;
              order_type = Order.Market;
              quantity = t.p.qty_per_add;
              time_in_force = Order.Good_till_cancel;
              client_order_id = Printf.sprintf "acc-%d" t.n;
              strategy_id = "accumulator";
              urgency = Action.Normal;
              tag = "";
            };
        ]
      else []
    | _ -> []


  let on_stop _ _ = []

  let diagnostics t = [ ("adds", float_of_int (t.n / 25)) ]
end

(* A falling market, so the accumulator digs itself into a drawdown and the gate has something to
   refuse. A drifting-up path would leave every limit slack and the comparison would be vacuous. *)
let falling_generator () =
  let series = MC.Generator.default_series ~symbol:"SYN" ~s0:100.0 in
    MC.Generator.Gbm { mu = -1.5; sigma = 0.45; dt = 0.004; series }


let base_config ?risk_limits () =
  let venue =
    Algostream_order_management.Venue.create ~name:"test"
      ~asset_class:Algostream_domain_market.Asset.Crypto
      ~fee_tiers:
        [
          {
            Algostream_order_management.Venue.maker_bps = 0.0;
            taker_bps = 0.0;
            volume_threshold = 0.0;
          };
        ]
      ~base_latency_us:0.0 ~supports_iceberg:true ~supports_stop:true ~min_order_size:0.0 in
  let c = BT.Engine.default_config ~venue ~initial_capital:100_000.0 in
    { c with BT.Engine.slippage = BT.Slippage.Fixed_bps 0.0; flatten_at_end = false; risk_limits }


let mc_config ~backtest =
  let c =
    MC.Engine.default_config ~n_runs:24 ~root_seed:20260808L ~generator:(falling_generator ())
      ~backtest in
    (* Single domain: this is about correctness of the pairing, and Pool determinism already has its
       own core-count test. *)
    { c with MC.Engine.n_domains = 1; n_steps = 600 }


let test_identical_arms_difference_to_exactly_zero () =
  let bt = base_config () in
  let cfg = mc_config ~backtest:bt in
  let a = MC.Engine.arm Accumulator.default_params in
  let b = MC.Engine.arm Accumulator.default_params in
  let cmp = MC.Engine.run_comparative (module Accumulator) ~a ~b ~config:cfg in
    Alcotest.(check int) "no run failed" 0 cmp.MC.Engine.n_failed ;
    Alcotest.(check bool) "metrics were produced" true (Array.length cmp.MC.Engine.per_metric > 0) ;
    Array.iter
      (fun (name, d) ->
        (* Exact zero, not approximate. Anything else means the arms saw different markets. *)
        Alcotest.(check (float 0.0)) (name ^ " mean difference") 0.0 d.Quantile.mean ;
        Alcotest.(check (float 0.0)) (name ^ " p05 difference") 0.0 d.Quantile.p05 ;
        Alcotest.(check (float 0.0)) (name ^ " p95 difference") 0.0 d.Quantile.p95)
      cmp.MC.Engine.per_metric


let test_identical_arms_stay_zero_when_one_carries_an_explicit_config () =
  (* arm_with must be a no-op when the config it supplies equals the shared one. This is what
     catches an arm-specific config accidentally perturbing root_seed or run_index. *)
  let bt = base_config () in
  let cfg = mc_config ~backtest:bt in
  let a = MC.Engine.arm Accumulator.default_params in
  let b = MC.Engine.arm_with Accumulator.default_params bt in
  let cmp = MC.Engine.run_comparative (module Accumulator) ~a ~b ~config:cfg in
    Alcotest.(check int) "no run failed" 0 cmp.MC.Engine.n_failed ;
    Array.iter
      (fun (name, d) ->
        Alcotest.(check (float 0.0)) (name ^ " mean difference") 0.0 d.Quantile.mean)
      cmp.MC.Engine.per_metric


let find cmp name =
  match Array.find_opt (fun (n, _) -> String.equal n name) cmp.MC.Engine.per_metric with
  | Some (_, d) -> d
  | None -> Alcotest.failf "metric %s missing from the comparison" name


let test_risk_limits_arm_changes_the_outcome () =
  (* The capability the drawdown experiment needs: A has no limits, B has a tight drawdown ceiling,
     everything else is identical including the market. *)
  let unlimited = base_config () in
  let limited =
    base_config
      ~risk_limits:
        {
          Risk_limits.default with
          max_drawdown = 0.05;
          max_daily_loss = 1e9;
          max_leverage = 1e9;
          max_position_concentration = 1e9;
          max_gross_exposure = 1e9;
        }
      () in
  let cfg = mc_config ~backtest:unlimited in
  let a = MC.Engine.arm Accumulator.default_params in
  let b = MC.Engine.arm_with Accumulator.default_params limited in
  let cmp = MC.Engine.run_comparative (module Accumulator) ~a ~b ~config:cfg in
  let dd = find cmp "max_drawdown" in
    Alcotest.(check int) "no run failed" 0 cmp.MC.Engine.n_failed ;
    (* B − A, and max_drawdown is a positive fraction, so capping it must come out negative. This is
       the assertion that would have been impossible before the gate consulted a drawdown at all:
       previously the limited arm was byte-identical to the unlimited one. *)
    Alcotest.(check bool)
      (Printf.sprintf "a 5%% drawdown ceiling reduces max drawdown (median diff %+.4f)"
         dd.Quantile.p50)
      true (dd.Quantile.p50 < 0.0)


let suite =
  [
    Alcotest.test_case "identical_arms_difference_to_exactly_zero" `Quick
      test_identical_arms_difference_to_exactly_zero;
    Alcotest.test_case "identical_arms_stay_zero_when_one_carries_an_explicit_config" `Quick
      test_identical_arms_stay_zero_when_one_carries_an_explicit_config;
    Alcotest.test_case "risk_limits_arm_changes_the_outcome" `Quick
      test_risk_limits_arm_changes_the_outcome;
  ]
