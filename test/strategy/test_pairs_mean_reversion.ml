(* The reference strategy is driven by feeding it scripted Pairs.Snapshot values and asserting the
   exact action list. No engine, no data — Strategy.S returns actions rather than invoking a submit
   callback precisely so this is possible. *)

module PMR = Algostream_strategy.Pairs_mean_reversion
module Strategy = Algostream_strategy.Strategy
module Action = Algostream_strategy.Action
module Event = Algostream_strategy.Event
module Context = Algostream_strategy.Context
module Side = Algostream_strategy.Side
module Snapshot = Algostream_pairs.Snapshot
module Mean_reversion = Algostream_pairs.Mean_reversion
module Pair_id = Algostream_pairs.Pair_id
module Symbol = Algostream_normalization.Symbol
module Portfolio = Algostream_domain_portfolio.Portfolio

let pid =
  Pair_id.of_symbols
    { Symbol.base = "BTC"; quote = "USDT"; asset_class = Symbol.Crypto }
    { Symbol.base = "ETH"; quote = "USDT"; asset_class = Symbol.Crypto }


(* A snapshot that passes every screen by default; individual tests break one field at a time. *)
let snap ?(ready = true) ?(cointegrated = true) ?(adf_p = 0.01) ?(corr = 0.9) ?(half_life = 10.0)
  ?(beta = 2.0) ?(py = 100.0) ?(px = 50.0) ~signal () =
  {
    Snapshot.pair = pid;
    last_event_ts_ns = 1_000_000_000L;
    n_ticks = 500;
    n_bars = 100;
    last_price_y = py;
    last_price_x = px;
    beta;
    beta_stdev = 0.05;
    intercept = 0.0;
    spread = 0.0;
    spread_mean = 0.0;
    spread_std = 1.0;
    z_score = 0.0;
    corr;
    adf_t_stat = -4.0;
    adf_p_value = adf_p;
    cointegrated;
    half_life_bars = half_life;
    avg_volume = 1000.0;
    signal;
    ready;
  }


let ctx ?(positions = []) ?(nav = 100_000.0) () =
  {
    Context.ts_ns = 1_000_000_000L;
    seq = 1;
    portfolio = Portfolio.create_portfolio ~account_id:"T" ~initial_capital:nav ();
    nav;
    working_orders = [];
    position = (fun s -> match List.assoc_opt s positions with Some q -> q | None -> 0.0);
    last_price = (fun _ -> Some 100.0);
    quote = (fun _ -> Some (99.0, 101.0));
    book = (fun _ -> None);
    risk = None;
  }


let fire st c s =
  PMR.on_event st c
    (Event.Pair_snapshot { snapshot = s; y_symbol = "BTCUSDT"; x_symbol = "ETHUSDT" })


let fresh () = PMR.create ~params:PMR.default_params ~symbols:[ "BTCUSDT"; "ETHUSDT" ]

let submits acts = List.filter_map (function Action.Submit i -> Some i | _ -> None) acts

let test_long_spread_buys_y_and_sells_x () =
  let st = fresh () in
  let acts = fire st (ctx ()) (snap ~signal:Mean_reversion.Long_spread ()) in
  let ss = submits acts in
    Alcotest.(check int) "two legs" 2 (List.length ss) ;
    let y = List.find (fun i -> String.equal i.Action.symbol "BTCUSDT") ss in
    let x = List.find (fun i -> String.equal i.Action.symbol "ETHUSDT") ss in
      Alcotest.(check bool) "buys the y leg" true (Side.equal y.Action.side Side.Buy) ;
      Alcotest.(check bool) "sells the x leg" true (Side.equal x.Action.side Side.Sell) ;
      Alcotest.(check string) "tagged" "long_spread" y.Action.tag


let test_short_spread_is_the_mirror () =
  let st = fresh () in
  let ss = submits (fire st (ctx ()) (snap ~signal:Mean_reversion.Short_spread ())) in
  let y = List.find (fun i -> String.equal i.Action.symbol "BTCUSDT") ss in
  let x = List.find (fun i -> String.equal i.Action.symbol "ETHUSDT") ss in
    Alcotest.(check bool) "sells the y leg" true (Side.equal y.Action.side Side.Sell) ;
    Alcotest.(check bool) "buys the x leg" true (Side.equal x.Action.side Side.Buy)


(* Hedge ratio: |qty_x| / |qty_y| must equal beta_hedge * beta. *)
let test_hedge_ratio_is_respected () =
  let st = fresh () in
  let beta = 2.0 in
  let ss = submits (fire st (ctx ()) (snap ~beta ~signal:Mean_reversion.Long_spread ())) in
  let y = List.find (fun i -> String.equal i.Action.symbol "BTCUSDT") ss in
  let x = List.find (fun i -> String.equal i.Action.symbol "ETHUSDT") ss in
  let ratio = x.Action.quantity /. y.Action.quantity in
    Alcotest.(check (float 1e-9)) "quantity ratio equals beta" beta ratio


let test_gross_notional_is_capped_by_nav () =
  let st = fresh () in
  (* Tiny NAV: the 30% cap binds well below the 10k target notional. *)
  let ss = submits (fire st (ctx ~nav:1000.0 ()) (snap ~signal:Mean_reversion.Long_spread ())) in
  let gross =
    List.fold_left
      (fun acc i ->
        acc +. (i.Action.quantity *. if String.equal i.Action.symbol "BTCUSDT" then 100.0 else 50.0))
      0.0 ss in
    Alcotest.(check bool)
      (Printf.sprintf "gross %.2f is within 30%% of the 1000 NAV" gross)
      true
      (gross <= 300.0 +. 1e-6)


(* THE idempotence test. The classifier repeats Long_spread for as long as z sits past the band; a
   strategy without this guard submits an entry on every tick. *)
let test_repeated_signal_is_ignored () =
  let st = fresh () in
  let c = ctx () in
  let s = snap ~signal:Mean_reversion.Long_spread () in
  let first = fire st c s in
  let second = fire st c s in
  let third = fire st c s in
    Alcotest.(check int) "the first crossing enters" 2 (List.length (submits first)) ;
    Alcotest.(check int) "the second emits nothing" 0 (List.length second) ;
    Alcotest.(check int) "and so does the third" 0 (List.length third)


let test_exit_flattens_actual_positions () =
  let st = fresh () in
  let c_in = ctx () in
    ignore (fire st c_in (snap ~signal:Mean_reversion.Long_spread ())) ;
    (* Report real positions so the flatten path has something to close. *)
    let c_out = ctx ~positions:[ ("BTCUSDT", 5.0); ("ETHUSDT", -10.0) ] () in
    let ss = submits (fire st c_out (snap ~signal:Mean_reversion.Exit ())) in
      Alcotest.(check int) "both legs closed" 2 (List.length ss) ;
      let y = List.find (fun i -> String.equal i.Action.symbol "BTCUSDT") ss in
      let x = List.find (fun i -> String.equal i.Action.symbol "ETHUSDT") ss in
        Alcotest.(check bool) "sells to close the long" true (Side.equal y.Action.side Side.Sell) ;
        Alcotest.(check (float 1e-9)) "the whole long" 5.0 y.Action.quantity ;
        Alcotest.(check bool) "buys to close the short" true (Side.equal x.Action.side Side.Buy) ;
        Alcotest.(check (float 1e-9)) "the whole short" 10.0 x.Action.quantity


let test_exit_with_no_position_does_nothing () =
  let st = fresh () in
    Alcotest.(check int)
      "no position, no actions" 0
      (List.length (fire st (ctx ()) (snap ~signal:Mean_reversion.Exit ())))


let test_hold_emits_nothing () =
  let st = fresh () in
    Alcotest.(check int)
      "hold is silent" 0
      (List.length (fire st (ctx ()) (snap ~signal:Mean_reversion.Hold ())))


let test_not_ready_is_skipped () =
  let st = fresh () in
    Alcotest.(check int)
      "an unready snapshot produces nothing" 0
      (List.length (fire st (ctx ()) (snap ~ready:false ~signal:Mean_reversion.Long_spread ()))) ;
    Alcotest.(check (float 1e-9))
      "and is counted" 1.0
      (List.assoc "skipped_not_ready" (PMR.diagnostics st))


(* Each screen, broken one at a time. *)
let test_screens_block_entry () =
  let cases =
    [
      ("not cointegrated", snap ~cointegrated:false ~signal:Mean_reversion.Long_spread ());
      ("adf p-value too high", snap ~adf_p:0.5 ~signal:Mean_reversion.Long_spread ());
      ("correlation too low", snap ~corr:0.1 ~signal:Mean_reversion.Long_spread ());
      ("half-life too short", snap ~half_life:0.5 ~signal:Mean_reversion.Long_spread ());
      ("half-life too long", snap ~half_life:5000.0 ~signal:Mean_reversion.Long_spread ());
      ("half-life not finite", snap ~half_life:Float.nan ~signal:Mean_reversion.Long_spread ());
    ] in
    List.iter
      (fun (name, s) ->
        let st = fresh () in
          Alcotest.(check int)
            (Printf.sprintf "%s blocks entry" name)
            0
            (List.length (fire st (ctx ()) s)))
      cases


(* A pair whose screen stops holding while a position is open must be flattened — the relationship
   the trade was predicated on is no longer demonstrable. *)
let test_screen_failure_flattens_an_open_position () =
  let st = fresh () in
    ignore (fire st (ctx ()) (snap ~signal:Mean_reversion.Long_spread ())) ;
    let c = ctx ~positions:[ ("BTCUSDT", 5.0); ("ETHUSDT", -10.0) ] () in
    let ss = submits (fire st c (snap ~cointegrated:false ~signal:Mean_reversion.Hold ())) in
      Alcotest.(check int) "both legs flattened" 2 (List.length ss) ;
      Alcotest.(check string) "tagged as a screen failure" "screen_failed" (List.hd ss).Action.tag ;
      Alcotest.(check (float 1e-9))
        "and counted" 1.0
        (List.assoc "forced_flat" (PMR.diagnostics st))


let test_on_stop_flattens () =
  let st = fresh () in
    ignore (fire st (ctx ()) (snap ~signal:Mean_reversion.Long_spread ())) ;
    let c = ctx ~positions:[ ("BTCUSDT", 3.0); ("ETHUSDT", -6.0) ] () in
    let ss = submits (PMR.on_stop st c) in
      Alcotest.(check int) "closes both legs at shutdown" 2 (List.length ss) ;
      Alcotest.(check string) "tagged" "on_stop" (List.hd ss).Action.tag


let test_limit_orders_rest_at_the_touch () =
  let params = { PMR.default_params with PMR.use_limit_orders = 1.0 } in
  let st = PMR.create ~params ~symbols:[ "BTCUSDT"; "ETHUSDT" ] in
  let ss = submits (fire st (ctx ()) (snap ~signal:Mean_reversion.Long_spread ())) in
  let y = List.find (fun i -> String.equal i.Action.symbol "BTCUSDT") ss in
    Alcotest.(check bool)
      "the buy leg rests at the bid" true
      (y.Action.order_type = Algostream_domain_orders.Order.Limit 99.0) ;
    Alcotest.(check bool)
      "and is passive, so it earns the maker fee" true
      (y.Action.urgency = Action.Passive)


let test_params_round_trip () =
  let p = PMR.default_params in
  let assoc = PMR.params_to_assoc p in
    match PMR.params_of_assoc assoc with
    | Error e -> Alcotest.failf "round trip failed: %s" e
    | Ok p' ->
      Alcotest.(check (float 1e-12))
        "target notional" p.PMR.target_gross_notional p'.PMR.target_gross_notional ;
      Alcotest.(check (float 1e-12)) "beta hedge" p.PMR.beta_hedge p'.PMR.beta_hedge


(* An optimizer that wanders outside the declared bounds must get a clear error, not a silently
   clamped evaluation reported as though it were the requested point. *)
let test_params_out_of_bounds_are_rejected () =
  let bad =
    List.map
      (fun (k, v) -> if String.equal k "beta_hedge" then (k, 99.0) else (k, v))
      (PMR.params_to_assoc PMR.default_params) in
    match PMR.params_of_assoc bad with
    | Error _ -> Alcotest.(check bool) "rejected" true true
    | Ok _ -> Alcotest.fail "an out-of-range parameter must be rejected"


let test_inconsistent_half_life_bounds_rejected () =
  let bad =
    List.map
      (fun (k, v) -> if String.equal k "min_half_life_bars" then (k, 40.0) else (k, v))
      (PMR.params_to_assoc { PMR.default_params with PMR.max_half_life_bars = 20.0 }) in
    match PMR.params_of_assoc bad with
    | Error msg -> Alcotest.(check bool) "explains the inconsistency" true (String.length msg > 10)
    | Ok _ -> Alcotest.fail "min >= max must be rejected"


let test_every_bound_is_reachable_by_the_optimizer () =
  let assoc = PMR.params_to_assoc PMR.default_params in
    List.iter
      (fun (name, _, _) ->
        Alcotest.(check bool)
          (Printf.sprintf "%s is present in params_to_assoc" name)
          true (List.mem_assoc name assoc))
      PMR.param_bounds ;
    Alcotest.(check int) "no extra fields" (List.length PMR.param_bounds) (List.length assoc)


let test_non_pair_events_are_ignored () =
  let st = fresh () in
  let c = ctx () in
    Alcotest.(check int)
      "ticks are ignored" 0
      (List.length
         (PMR.on_event st c
            (Event.Tick
               { symbol = "BTCUSDT"; ts_ns = 1L; price = 1.0; volume = 1.0; bid = None; ask = None }))) ;
    Alcotest.(check int)
      "timers are ignored" 0
      (List.length (PMR.on_event st c (Event.Timer { ts_ns = 1L; tag = "t" })))


let suite =
  [
    Alcotest.test_case "long_spread_buys_y_and_sells_x" `Quick test_long_spread_buys_y_and_sells_x;
    Alcotest.test_case "short_spread_is_the_mirror" `Quick test_short_spread_is_the_mirror;
    Alcotest.test_case "hedge_ratio_is_respected" `Quick test_hedge_ratio_is_respected;
    Alcotest.test_case "gross_notional_is_capped_by_nav" `Quick test_gross_notional_is_capped_by_nav;
    Alcotest.test_case "repeated_signal_is_ignored" `Quick test_repeated_signal_is_ignored;
    Alcotest.test_case "exit_flattens_actual_positions" `Quick test_exit_flattens_actual_positions;
    Alcotest.test_case "exit_with_no_position_does_nothing" `Quick
      test_exit_with_no_position_does_nothing;
    Alcotest.test_case "hold_emits_nothing" `Quick test_hold_emits_nothing;
    Alcotest.test_case "not_ready_is_skipped" `Quick test_not_ready_is_skipped;
    Alcotest.test_case "screens_block_entry" `Quick test_screens_block_entry;
    Alcotest.test_case "screen_failure_flattens_an_open_position" `Quick
      test_screen_failure_flattens_an_open_position;
    Alcotest.test_case "on_stop_flattens" `Quick test_on_stop_flattens;
    Alcotest.test_case "limit_orders_rest_at_the_touch" `Quick test_limit_orders_rest_at_the_touch;
    Alcotest.test_case "params_round_trip" `Quick test_params_round_trip;
    Alcotest.test_case "params_out_of_bounds_are_rejected" `Quick
      test_params_out_of_bounds_are_rejected;
    Alcotest.test_case "inconsistent_half_life_bounds_rejected" `Quick
      test_inconsistent_half_life_bounds_rejected;
    Alcotest.test_case "every_bound_is_reachable_by_the_optimizer" `Quick
      test_every_bound_is_reachable_by_the_optimizer;
    Alcotest.test_case "non_pair_events_are_ignored" `Quick test_non_pair_events_are_ignored;
  ]
