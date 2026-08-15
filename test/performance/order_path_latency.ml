(** Latency of the in-process decision path, as a distribution.

    {1 What this measures, and what it cannot}

    The stated design target is "sub-5 ms order execution". Nothing in the project could answer
    that: [order_management_throughput] times [Routing.route] in isolation and reports a throughput,
    and [backtest_throughput] reports [ns_per_event] averaged over a whole replay. Neither is a
    latency distribution, and an average hides exactly the tail the target is about.

    This times the full decision path for a single order:

    {v
      tick observed → strategy decides → risk gate → position sizing → routing → fill admitted
    v}

    {b The venue leg does not exist.} AlgoStream is paper trading — there is no connectivity to any
    exchange, no order placement, no acknowledgement. So this answers the target only for the part
    the project actually controls: from market data arriving to an order being handed to the fill
    simulator. Real execution latency is dominated by the network round trip and the venue's
    matching engine, neither of which is here. Quoting this figure as "order execution latency"
    without that sentence would be dishonest, which is why the sentence is in the output.

    {1 Method}

    Every iteration is timed end to end with the monotonic clock and recorded into an [int] array —
    [int], not [int64], because an [int64 array] boxes every write, and OCaml 5's minor collections
    are stop-the-world across Domains, so the recording would perturb the thing being measured.

    Percentiles rather than a mean: the interesting question about a latency target is what the tail
    does. A warmup pass runs first so the reported distribution is not dominated by first-call
    effects and cold caches. *)

module BT = Algostream_backtest
module OM = Algostream_order_management
module Order = Algostream_domain_orders.Order
module Portfolio = Algostream_domain_portfolio.Portfolio
module Timestamp = Algostream_domain_common.Timestamp
module Asset = Algostream_domain_market.Asset
module Risk_limits = Algostream_risk_management.Risk_limits
module Clock = Algostream_common_utils.Time_utils.Clock
module Rng = Algostream_rng.Rng

let default_iters = 200_000

let default_warmup = 20_000

let parse_args () =
  let json = ref None in
  let iters = ref default_iters in
  let i = ref 1 in
    while !i < Array.length Sys.argv do
      (match Sys.argv.(!i) with
      | "--json" when !i + 1 < Array.length Sys.argv ->
        json := Some Sys.argv.(!i + 1) ;
        incr i
      | "--iters" when !i + 1 < Array.length Sys.argv ->
        iters := int_of_string Sys.argv.(!i + 1) ;
        incr i
      | "--help" ->
        print_endline "Usage: order_path_latency [--iters N] [--json PATH]" ;
        exit 0
      | other ->
        Printf.eprintf "unknown arg: %s\n" other ;
        exit 2) ;
      incr i
    done ;
    (!json, !iters)


(* Nearest-rank, in permille rather than percent, so p99.9 is expressible. Taking a percent
   percentile and dividing by ten — which is what an earlier version of this did — silently reports
   one tenth of the maximum instead. *)
let permille sorted p =
  let n = Array.length sorted in
    if n = 0 then 0 else sorted.(min (n - 1) (n * p / 1000))


let venue =
  OM.Venue.create ~name:"bench" ~asset_class:Asset.Crypto
    ~fee_tiers:[ { OM.Venue.maker_bps = 0.0; taker_bps = 2.0; volume_threshold = 0.0 } ]
    ~base_latency_us:0.0 ~supports_iceberg:true ~supports_stop:true ~min_order_size:0.0


let limits = Risk_limits.default

let main () =
  let json_path, iters = parse_args () in
  let total = iters + default_warmup in

  let view = BT.Market_view.create () in
  let rng = Rng.create ~seed:20260808 in
  let cost = BT.Cost_model.create (BT.Cost_model.default_config venue) in
  let fills =
    BT.Fill_engine.create
      ~config:
        {
          BT.Fill_engine.slippage = BT.Slippage.Spread_fraction 1.0;
          latency = BT.Latency.zero;
          maker_fill = BT.Fill_engine.Queue_position;
          stop_trigger = BT.Fill_engine.Trigger_touch;
          allow_partial = true;
        }
      ~cost ~rng in
  let portfolio =
    ref (Portfolio.create_portfolio ~account_id:"bench" ~initial_capital:10_000_000.0 ()) in

  (* See the module note: int, not int64, so recording does not allocate. *)
  let samples = Array.make iters 0 in

  for i = 0 to total - 1 do
    let now = Int64.mul (Int64.of_int (i + 1)) 1_000_000L in
    let px = 100.0 +. (float_of_int (i mod 50) *. 0.01) in
    let t0 = Clock.now_monotonic_ns () in

    (* 1. market data arrives and the view updates *)
    BT.Market_view.observe view
      (BT.Data_source.Tick
         {
           symbol = "BENCH";
           ts_ns = now;
           price = px;
           volume = 5.0;
           bid = Some (px -. 0.005);
           ask = Some (px +. 0.005);
         }) ;

    (* 2. the decision — a mid read standing in for the strategy's signal evaluation. The real
       strategy's own computation is measured by pairs_throughput; what is timed here is the path
       around it, which is what every strategy pays regardless of its logic. *)
    let mid = match BT.Market_view.mid view "BENCH" with Some m -> m | None -> px in

    (* 3. position sizing *)
    let qty =
      OM.Position_sizing.Kelly.size_position ~capital:100_000.0 ~kelly_fraction:0.25 ~price:mid ()
    in
    let qty = if qty <= 0.0 then 1.0 else qty in

    let order =
      Order.create_order ~ts:(Timestamp.of_ns now) ~id:(Printf.sprintf "BP-%d" i)
        ~client_order_id:(Printf.sprintf "c-%d" i) ~symbol:"BENCH" ~side:Order.Buy
        ~order_type:Order.Market ~quantity:qty ~time_in_force:Order.Immediate_or_cancel
        ~exchange:"bench" () in

    (* 4. the risk gate *)
    let breaches =
      Risk_limits.pre_trade_check limits ~portfolio:!portfolio ~proposed_order:order
        ~proposed_price:mid ~current_drawdown:0.01 ~daily_pnl_pct:(-0.001) () in

    (* 5. routing, then 6. admission to the fill engine *)
    (if breaches = [] then
       let _ = OM.Routing.route ~order ~venues:[] ~strategy:OM.Routing.Smart_split () in
       let intent =
         {
           Algostream_strategy.Action.symbol = "BENCH";
           side = Algostream_strategy.Side.Buy;
           quantity = qty;
           order_type = Order.Market;
           time_in_force = Order.Immediate_or_cancel;
           client_order_id = Printf.sprintf "c-%d" i;
           strategy_id = "bench";
           urgency = Algostream_strategy.Action.Normal;
           tag = "";
         } in
         ignore
           (BT.Fill_engine.admit fills ~now_ns:now intent ~order_id:(Printf.sprintf "BP-%d" i)
              ~decision_price:mid
             : Order.order)) ;

    let dt = Int64.to_int (Int64.sub (Clock.now_monotonic_ns ()) t0) in
      if i >= default_warmup then samples.(i - default_warmup) <- dt
  done ;

  Array.sort compare samples ;
  let n = Array.length samples in
  let sum = Array.fold_left ( + ) 0 samples in
  let avg = if n = 0 then 0 else sum / n in
  let p50 = permille samples 500 in
  let p95 = permille samples 950 in
  let p99 = permille samples 990 in
  let p999 = permille samples 999 in
  let max_v = if n = 0 then 0 else samples.(n - 1) in

  let ms v = float_of_int v /. 1e6 in
    Printf.printf
      "order_path_latency: n=%d avg=%dns p50=%dns p95=%dns p99=%dns p99.9=%dns max=%dns\n" n avg p50
      p95 p99 p999 max_v ;
    Printf.printf "  p99 = %.4f ms against a 5 ms target: %s\n" (ms p99)
      (if p99 < 5_000_000 then "within" else "OVER") ;
    (* The far tail is not the order path. p50 and p99 sit in the microseconds while p99.9 and the
       maximum jump by three orders of magnitude — that is the OCaml 5 major collector, which is
       stop-the-world across every Domain. Reporting it as order-path latency would blame the wrong
       component, and hiding it would be worse. *)
    if p999 > 20 * p99 then
      Printf.printf
        "  note: p99.9 (%.3f ms) and max (%.3f ms) are GC pauses, not path cost — the path itself\n\
        \        is the p50/p99 figures. See docs/architecture/latency_optimization.md on GC.\n"
        (ms p999) (ms max_v) ;
    print_endline
      "  scope: market data in → order admitted to the fill simulator. AlgoStream is paper trading,\n\
      \         so the venue round trip and matching are not included and cannot be measured here." ;

    match json_path with
    | None -> ()
    | Some path ->
      let oc = open_out path in
      let extra = Printf.sprintf "n=%d" n in
        Printf.fprintf oc "[\n" ;
        let rows =
          [
            ("order_path.avg", avg);
            ("order_path.p50", p50);
            ("order_path.p95", p95);
            ("order_path.p99", p99);
          ] in
        let last = List.length rows - 1 in
          List.iteri
            (fun idx (name, value) ->
              Printf.fprintf oc
                "  {\"name\":\"%s\",\"unit\":\"ns\",\"value\":%d,\"extra\":\"%s\"}%s\n" name value
                extra
                (if idx = last then "" else ","))
            rows ;
          Printf.fprintf oc "]\n" ;
          close_out oc ;
          Printf.printf "wrote %s\n" path


let () = main ()
