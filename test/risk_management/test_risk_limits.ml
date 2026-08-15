open Algostream_risk_management
module Order = Algostream_domain_orders.Order

let test_within_limits_no_breach () =
  let p = Helpers.make_portfolio () in
  let order = Helpers.make_order ~quantity:1.0 () in
  let limits = Risk_limits.default in
  let breaches = Risk_limits.pre_trade_check limits ~portfolio:p ~proposed_order:order () in
    Alcotest.(check int) "empty portfolio = no breaches" 0 (List.length breaches)


let test_leverage_breach () =
  let p =
    Helpers.portfolio_with_positions ~nav:10_000.0
      ~positions:[ ("BTCUSDT", 100.0, 1000.0) (* $100k exposure on $10k NAV → 10x leverage *) ]
      () in
  let order = Helpers.make_order ~quantity:1.0 () in
  let limits = { Risk_limits.default with max_leverage = 3.0 } in
  let breaches = Risk_limits.pre_trade_check limits ~portfolio:p ~proposed_order:order () in
    Alcotest.(check bool)
      "leverage breach detected" true
      (List.exists (function Risk_limits.Leverage _ -> true | _ -> false) breaches)


let test_position_concentration_breach () =
  let p =
    Helpers.portfolio_with_positions ~nav:100_000.0
      ~positions:[ ("BTCUSDT", 60.0, 1000.0) (* $60k on $100k NAV → 60% concentration *) ]
      () in
  let order = Helpers.make_order ~quantity:1.0 () in
  let limits = { Risk_limits.default with max_position_concentration = 0.25 } in
  let breaches = Risk_limits.pre_trade_check limits ~portfolio:p ~proposed_order:order () in
    Alcotest.(check bool)
      "position concentration breach detected" true
      (List.exists (function Risk_limits.Position_concentration _ -> true | _ -> false) breaches)


let test_proposed_order_pushes_breach () =
  (* Existing 20% position; proposed order would push to 40% *)
  let p =
    Helpers.portfolio_with_positions ~nav:100_000.0 ~positions:[ ("BTCUSDT", 20.0, 1000.0) ] ()
  in
  let order = Helpers.make_order ~quantity:20.0 ~symbol:"BTCUSDT" () in
  let limits = { Risk_limits.default with max_position_concentration = 0.25 } in
  let breaches =
    Risk_limits.pre_trade_check limits ~portfolio:p ~proposed_order:order ~proposed_price:1000.0 ()
  in
    Alcotest.(check bool)
      "proposed-trade simulated breach" true
      (List.exists (function Risk_limits.Position_concentration _ -> true | _ -> false) breaches)


(* Path-dependent limits.

   Drawdown and Daily_loss were declared in the breach type and printed by breach_to_string, but
   pre_trade_check could not produce either: it saw only a portfolio snapshot, which carries no
   history. max_drawdown was therefore read by nothing on the trading path and setting it did
   nothing. These cases exist so that regressing to a snapshot-only gate fails loudly. *)

let dd_limits = { Risk_limits.default with max_drawdown = 0.20; max_daily_loss = 0.05 }

let test_drawdown_breach_fires () =
  let p = Helpers.make_portfolio () in
  let order = Helpers.make_order ~quantity:1.0 () in
  let breaches =
    Risk_limits.pre_trade_check dd_limits ~portfolio:p ~proposed_order:order ~current_drawdown:0.25
      () in
    Alcotest.(check bool)
      "25% drawdown against a 20% limit is a breach" true
      (List.exists (function Risk_limits.Drawdown _ -> true | _ -> false) breaches)


let test_drawdown_inside_limit_is_silent () =
  (* The companion that catches an off-by-one in the comparison direction. Checking only the firing
     case would pass with [>=] against 0.0, which would reject every order. *)
  let p = Helpers.make_portfolio () in
  let order = Helpers.make_order ~quantity:1.0 () in
  let breaches =
    Risk_limits.pre_trade_check dd_limits ~portfolio:p ~proposed_order:order ~current_drawdown:0.15
      () in
    Alcotest.(check bool)
      "15% drawdown against a 20% limit is not a breach" false
      (List.exists (function Risk_limits.Drawdown _ -> true | _ -> false) breaches)


let test_flat_equity_never_breaches () =
  (* Omitting the arguments must disable the checks, not trip them — every existing caller that has
     not been updated relies on the defaults being inert. *)
  let p = Helpers.make_portfolio () in
  let order = Helpers.make_order ~quantity:1.0 () in
  let breaches = Risk_limits.pre_trade_check dd_limits ~portfolio:p ~proposed_order:order () in
    Alcotest.(check int) "no drawdown or daily-loss breach at defaults" 0 (List.length breaches)


let test_daily_loss_breach_fires () =
  let p = Helpers.make_portfolio () in
  let order = Helpers.make_order ~quantity:1.0 () in
  let breaches =
    Risk_limits.pre_trade_check dd_limits ~portfolio:p ~proposed_order:order ~daily_pnl_pct:(-0.08)
      () in
    Alcotest.(check bool)
      "-8% on the day against a 5% limit is a breach" true
      (List.exists (function Risk_limits.Daily_loss _ -> true | _ -> false) breaches)


let test_daily_gain_is_not_a_loss () =
  (* daily_pnl_pct is signed. Comparing its magnitude rather than its negation would make a
     profitable day trip the loss limit. *)
  let p = Helpers.make_portfolio () in
  let order = Helpers.make_order ~quantity:1.0 () in
  let breaches =
    Risk_limits.pre_trade_check dd_limits ~portfolio:p ~proposed_order:order ~daily_pnl_pct:0.08 ()
  in
    Alcotest.(check bool)
      "+8% on the day is not a daily-loss breach" false
      (List.exists (function Risk_limits.Daily_loss _ -> true | _ -> false) breaches)


let test_reported_values_are_the_breached_ones () =
  (* breach_to_string renders these; a swapped current/limit reads plausibly and is easy to miss. *)
  let p = Helpers.make_portfolio () in
  let order = Helpers.make_order ~quantity:1.0 () in
  let breaches =
    Risk_limits.pre_trade_check dd_limits ~portfolio:p ~proposed_order:order ~current_drawdown:0.33
      () in
    match List.find_opt (function Risk_limits.Drawdown _ -> true | _ -> false) breaches with
    | Some (Risk_limits.Drawdown { current; limit }) ->
      Alcotest.(check (float 1e-12)) "current is the observed drawdown" 0.33 current ;
      Alcotest.(check (float 1e-12)) "limit is the configured ceiling" 0.20 limit
    | _ -> Alcotest.fail "expected a Drawdown breach"


(* Risk-reducing orders are never blocked.

   The gate runs on every submit, including the order that closes a position. Blocking those made
   the drawdown limit actively harmful: once equity breached the ceiling the strategy could not exit
   the position that caused the breach, so the loss the limit existed to cap ran on unbounded.

   Measured on an hour of real Coinbase data before this exemption: a binding ceiling rejected 10 of
   12 orders and left max drawdown *higher* and total return *lower* than running with no limits at
   all. After it, the same comparison reduces max drawdown by 37% and improves return. *)

let a_long_position ~nav ~qty ~price =
  Helpers.portfolio_with_positions ~nav ~positions:[ ("BTCUSDT", qty, price) ] ()


let breached = { Risk_limits.default with max_drawdown = 0.05; max_leverage = 0.001 }

let test_closing_a_position_is_allowed_while_breached () =
  (* Leverage is set so low that an entry is refused outright, and drawdown is well past its
     ceiling. The exit must still go through. *)
  let p = a_long_position ~nav:100_000.0 ~qty:100.0 ~price:1000.0 in
  let exit_order = Helpers.make_order ~symbol:"BTCUSDT" ~side:Order.Sell ~quantity:100.0 () in
  let breaches =
    Risk_limits.pre_trade_check breached ~portfolio:p ~proposed_order:exit_order
      ~proposed_price:1000.0 ~current_drawdown:0.40 ~daily_pnl_pct:(-0.50) () in
    Alcotest.(check int) "flattening a position is never gated" 0 (List.length breaches)


let test_partial_reduction_is_allowed () =
  let p = a_long_position ~nav:100_000.0 ~qty:100.0 ~price:1000.0 in
  let trim = Helpers.make_order ~symbol:"BTCUSDT" ~side:Order.Sell ~quantity:40.0 () in
  let breaches =
    Risk_limits.pre_trade_check breached ~portfolio:p ~proposed_order:trim ~proposed_price:1000.0
      ~current_drawdown:0.40 () in
    Alcotest.(check int) "trimming is a reduction too" 0 (List.length breaches)


let test_adding_to_a_position_is_still_gated () =
  (* The control. If the exemption were "any order in a symbol we hold", the gate would be
     useless. *)
  let p = a_long_position ~nav:100_000.0 ~qty:100.0 ~price:1000.0 in
  let add = Helpers.make_order ~symbol:"BTCUSDT" ~side:Order.Buy ~quantity:10.0 () in
  let breaches =
    Risk_limits.pre_trade_check breached ~portfolio:p ~proposed_order:add ~proposed_price:1000.0
      ~current_drawdown:0.40 () in
    Alcotest.(check bool) "adding while breached is refused" true (List.length breaches > 0)


let test_flipping_through_flat_is_gated () =
  (* Selling 250 against a 100 long closes the position and opens a 150 short. That is an entry, and
     exempting it would let a strategy take unlimited new risk by routing it through a reversal. *)
  let p = a_long_position ~nav:100_000.0 ~qty:100.0 ~price:1000.0 in
  let flip = Helpers.make_order ~symbol:"BTCUSDT" ~side:Order.Sell ~quantity:250.0 () in
  let breaches =
    Risk_limits.pre_trade_check breached ~portfolio:p ~proposed_order:flip ~proposed_price:1000.0
      ~current_drawdown:0.40 () in
    Alcotest.(check bool)
      "an over-sized reversal is an entry, not a reduction" true
      (List.length breaches > 0)


let test_covering_a_short_is_allowed () =
  (* The sign-symmetric case; a check written only for longs would refuse this. *)
  let p = a_long_position ~nav:100_000.0 ~qty:(-100.0) ~price:1000.0 in
  let cover = Helpers.make_order ~symbol:"BTCUSDT" ~side:Order.Buy ~quantity:100.0 () in
  let breaches =
    Risk_limits.pre_trade_check breached ~portfolio:p ~proposed_order:cover ~proposed_price:1000.0
      ~current_drawdown:0.40 () in
    Alcotest.(check int) "covering a short is a reduction" 0 (List.length breaches)


let test_an_order_in_an_unheld_symbol_is_gated () =
  let p = a_long_position ~nav:100_000.0 ~qty:100.0 ~price:1000.0 in
  let other = Helpers.make_order ~symbol:"ETHUSDT" ~side:Order.Sell ~quantity:10.0 () in
  let breaches =
    Risk_limits.pre_trade_check breached ~portfolio:p ~proposed_order:other ~proposed_price:1000.0
      ~current_drawdown:0.40 () in
    Alcotest.(check bool)
      "a sell in a symbol we do not hold opens a short" true
      (List.length breaches > 0)


let suite =
  [
    Alcotest.test_case "within_limits_no_breach" `Quick test_within_limits_no_breach;
    Alcotest.test_case "closing_a_position_is_allowed_while_breached" `Quick
      test_closing_a_position_is_allowed_while_breached;
    Alcotest.test_case "partial_reduction_is_allowed" `Quick test_partial_reduction_is_allowed;
    Alcotest.test_case "adding_to_a_position_is_still_gated" `Quick
      test_adding_to_a_position_is_still_gated;
    Alcotest.test_case "flipping_through_flat_is_gated" `Quick test_flipping_through_flat_is_gated;
    Alcotest.test_case "covering_a_short_is_allowed" `Quick test_covering_a_short_is_allowed;
    Alcotest.test_case "an_order_in_an_unheld_symbol_is_gated" `Quick
      test_an_order_in_an_unheld_symbol_is_gated;
    Alcotest.test_case "leverage_breach" `Quick test_leverage_breach;
    Alcotest.test_case "position_concentration_breach" `Quick test_position_concentration_breach;
    Alcotest.test_case "proposed_order_pushes_breach" `Quick test_proposed_order_pushes_breach;
    Alcotest.test_case "drawdown_breach_fires" `Quick test_drawdown_breach_fires;
    Alcotest.test_case "drawdown_inside_limit_is_silent" `Quick test_drawdown_inside_limit_is_silent;
    Alcotest.test_case "flat_equity_never_breaches" `Quick test_flat_equity_never_breaches;
    Alcotest.test_case "daily_loss_breach_fires" `Quick test_daily_loss_breach_fires;
    Alcotest.test_case "daily_gain_is_not_a_loss" `Quick test_daily_gain_is_not_a_loss;
    Alcotest.test_case "reported_values_are_the_breached_ones" `Quick
      test_reported_values_are_the_breached_ones;
  ]
