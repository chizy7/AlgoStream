(* Live runner vs backtest engine: same strategy, same records, same behaviour.

   This is the test that justifies the whole design. [Strategy.S] was written so that [on_event]
   returns actions rather than submitting them, precisely so a backtest and a live runner could
   drive one strategy without either being baked into the emit path. If the two drivers disagree,
   then every backtested number is a claim about a system that does not exist.

   Both are configured identically — zero latency, the same slippage and cost models, the same seed
   — and fed the same record sequence. Then the fills, the counters and the NAV must agree
   exactly. *)

module Data_source = Algostream_backtest.Data_source
module Engine = Algostream_backtest.Engine
module Result_ = Algostream_backtest.Result
module Latency = Algostream_backtest.Latency
module Slippage = Algostream_backtest.Slippage
module Fill_engine = Algostream_backtest.Fill_engine
module Cost_model = Algostream_backtest.Cost_model
module Venue = Algostream_order_management.Venue
module Strategy = Algostream_strategy.Strategy
module Action = Algostream_strategy.Action
module Event = Algostream_strategy.Event
module Side = Algostream_strategy.Side
module Order = Algostream_domain_orders.Order
module Instance = Algostream_runtime.Instance
module Snapshot = Algostream_runtime.Snapshot

(* A strategy with no cleverness at all: buy once at tick 10, sell once at tick 60. Deterministic,
   so any divergence between the drivers is the drivers' fault. *)
module Ping_pong : Strategy.S with type params = float = struct
  let name = "ping_pong"

  let version = "1.0"

  type params = float

  let default_params = 1.0

  let params_of_assoc a = match List.assoc_opt "qty" a with Some q -> Ok q | None -> Ok 1.0

  let params_to_assoc q = [ ("qty", q) ]

  let param_bounds = [ ("qty", 0.001, 1000.0) ]

  type state = {
    qty : float;
    mutable n : int;
    mutable submitted : int;
  }

  let create ~params ~symbols:_ = { qty = params; n = 0; submitted = 0 }

  let subscriptions _ = [ Strategy.Symbol "TESTUSD" ]

  let on_event st _ctx ev =
    match ev with
    | Event.Tick _ ->
      st.n <- st.n + 1 ;
      if st.n = 10 then (
        st.submitted <- st.submitted + 1 ;
        [
          Action.submit ~symbol:"TESTUSD" ~side:Side.Buy ~quantity:st.qty ~order_type:Order.Market
            ~client_order_id:"pp-buy" ~strategy_id:"pp" ();
        ])
      else if st.n = 60 then (
        st.submitted <- st.submitted + 1 ;
        [
          Action.submit ~symbol:"TESTUSD" ~side:Side.Sell ~quantity:st.qty ~order_type:Order.Market
            ~client_order_id:"pp-sell" ~strategy_id:"pp" ();
        ])
      else []
    | _ -> []


  let on_stop _ _ = []

  let diagnostics st = [ ("ticks", float_of_int st.n); ("submitted", float_of_int st.submitted) ]
end

(* A gently trending book so market orders have something to cross into. *)
let records n =
  Array.init n (fun i ->
    let px = 100.0 +. (float_of_int i *. 0.01) in
      Data_source.Tick
        {
          symbol = "TESTUSD";
          ts_ns = Int64.of_int ((i + 1) * 1_000_000_000);
          price = px;
          volume = 25.0;
          bid = Some (px -. 0.01);
          ask = Some (px +. 0.01);
        })


let venue = Venue.binance_spot

let capital = 100_000.0

let run_backtest recs =
  let config =
    {
      (Engine.default_config ~venue ~initial_capital:capital) with
      Engine.slippage = Slippage.Spread_fraction 1.0;
      latency = Latency.zero;
      maker_fill = Fill_engine.Queue_position;
      risk_limits = None;
      flatten_at_end = false (* the live runner has no equivalent; compare like with like *);
    } in
    Engine.run
      (module Ping_pong)
      ~params:Ping_pong.default_params ~config ~data:(Data_source.of_records recs)


let run_live recs =
  let config =
    {
      (Instance.default_config ~strategy_id:"pp" ~venue ~initial_capital:capital) with
      Instance.slippage = Slippage.Spread_fraction 1.0;
      latency = Latency.zero;
      maker_fill = Fill_engine.Queue_position;
      risk_limits = None;
      nav_sample_interval_ns = 0L;
    } in
  let inst = Instance.create (module Ping_pong) ~params:Ping_pong.default_params ~config in
    Array.iter (fun r -> Instance.on_record inst r) recs ;
    inst


let approx name a b =
  Alcotest.(check bool)
    (Printf.sprintf "%s: live %.8f vs backtest %.8f" name a b)
    true
    (Float.abs (a -. b) <= 1e-6 *. Float.max 1.0 (Float.abs b))


let test_fills_agree () =
  let recs = records 100 in
  let bt = run_backtest recs in
  let live = Instance.snapshot (run_live recs) in
  let bt_blotter = bt.Result_.blotter in
  let live_fills = List.rev live.Snapshot.recent_fills in
    Alcotest.(check int) "same number of fills" (Array.length bt_blotter) (List.length live_fills) ;
    List.iteri
      (fun i (f : Snapshot.fill) ->
        let b = bt_blotter.(i) in
          Alcotest.(check string)
            (Printf.sprintf "fill %d symbol" i)
            b.Result_.symbol f.Snapshot.symbol ;
          Alcotest.(check string)
            (Printf.sprintf "fill %d side" i) (Side.to_string b.Result_.side)
            (Side.to_string f.Snapshot.side) ;
          approx (Printf.sprintf "fill %d quantity" i) f.Snapshot.quantity b.Result_.quantity ;
          approx (Printf.sprintf "fill %d price" i) f.Snapshot.price b.Result_.price ;
          approx (Printf.sprintf "fill %d commission" i) f.Snapshot.commission b.Result_.commission)
      live_fills


let test_counters_and_nav_agree () =
  let recs = records 100 in
  let bt = run_backtest recs in
  let live = Instance.snapshot (run_live recs) in
  let c = bt.Result_.counters in
    Alcotest.(check int) "events" c.Result_.n_events live.Snapshot.n_events ;
    Alcotest.(check int) "actions" c.Result_.n_actions live.Snapshot.n_actions ;
    Alcotest.(check int) "submitted" c.Result_.n_submitted live.Snapshot.n_submitted ;
    Alcotest.(check int) "fills" c.Result_.n_fills live.Snapshot.n_fills ;
    Alcotest.(check int)
      "rejected by risk" c.Result_.n_rejected_by_risk live.Snapshot.n_rejected_by_risk ;
    let bt_nav =
      let curve = Result_.nav_curve bt in
        if Array.length curve = 0 then capital else snd curve.(Array.length curve - 1) in
      approx "final NAV" live.Snapshot.nav bt_nav


(* Feeding the same records twice must land in the same place — the live runner has no clock
   dependence inside the strategy path, so it is reproducible even though it is not a backtest. *)
let test_live_is_reproducible () =
  let recs = records 100 in
  let a = Instance.snapshot (run_live recs) in
  let b = Instance.snapshot (run_live recs) in
    approx "nav" a.Snapshot.nav b.Snapshot.nav ;
    approx "realized" a.Snapshot.realized_pnl b.Snapshot.realized_pnl ;
    Alcotest.(check int) "fills" a.Snapshot.n_fills b.Snapshot.n_fills


let suite =
  [
    Alcotest.test_case "fills_agree" `Quick test_fills_agree;
    Alcotest.test_case "counters_and_nav_agree" `Quick test_counters_and_nav_agree;
    Alcotest.test_case "live_is_reproducible" `Quick test_live_is_reproducible;
  ]
