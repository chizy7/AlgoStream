(** algostream-backtest — replay a recorded event log through a strategy, with realistic costs.

    Usage:
    {v
    algostream-backtest --log path/to/log.bin --y BTCUSDT --x ETHUSDT
                        [--capital 100000] [--venue binance|coinbase|free]
                        [--slippage book|spread|fixed:BPS|regime]
                        [--latency-us 0] [--maker-fill queue|touch|optimistic]
                        [--fees] [--risk-limits]
                        [--mc-runs N] [--seed N] [--domains N]
                        [--equity-csv PATH] [--blotter-csv PATH]
    v}

    Reads the log offline via [Event_log.Reader] — no event bus, no dispatcher Domain — so two runs
    over the same file produce byte-identical output. Argument parsing is a hand-rolled [Sys.argv]
    loop, matching [bin/bars.ml] and [bin/ingest.ml]. *)

module BT = Algostream_backtest
module MC = Algostream_montecarlo
module Perf = Algostream_performance
module PMR = Algostream_strategy.Pairs_mean_reversion
module Pair_id = Algostream_pairs.Pair_id
module Symbol = Algostream_normalization.Symbol
module Venue = Algostream_order_management.Venue
module Risk_limits = Algostream_risk_management.Risk_limits

type cli = {
  log_path : string option;
  y_symbol : string;
  x_symbol : string;
  capital : float;
  venue_name : string;
  slippage : string;
  latency_us : float;
  maker_fill : string;
  charge_fees : bool;
  risk_limits : bool;
  mc_runs : int;
  seed : int64;
  domains : int;
  equity_csv : string option;
  blotter_csv : string option;
  interval_ns : int64;
  bar_interval_ns : int64;
  compare_risk_limits : bool;
  max_drawdown : float;
}

let default_cli =
  {
    log_path = None;
    y_symbol = "BTCUSDT";
    x_symbol = "ETHUSDT";
    capital = 100_000.0;
    venue_name = "binance";
    slippage = "spread";
    latency_us = 0.0;
    maker_fill = "queue";
    charge_fees = false;
    risk_limits = false;
    mc_runs = 0;
    seed = 42L;
    domains = 0;
    equity_csv = None;
    blotter_csv = None;
    interval_ns = 60_000_000_000L;
    bar_interval_ns = 60_000_000_000L;
    compare_risk_limits = false;
    max_drawdown = Risk_limits.default.Risk_limits.max_drawdown;
  }


(* Shared by --interval and --bar-interval, which previously had one hand-inlined parser between
   them. *)
let duration_ns s flag =
  let last = String.length s - 1 in
  let mult =
    if last < 0 then (
      Printf.eprintf "%s needs a value like 30s, 5m or 1h\n" flag ;
      exit 2)
    else
      match s.[last] with
      | 's' -> 1_000_000_000L
      | 'm' -> 60_000_000_000L
      | 'h' -> 3_600_000_000_000L
      | _ ->
        Printf.eprintf "%s must end in s|m|h\n" flag ;
        exit 2 in
    Int64.mul (Int64.of_string (String.sub s 0 last)) mult


let usage =
  "Usage: algostream-backtest --log PATH [--y SYM] [--x SYM] [--capital N]\n\
  \                           [--venue binance|coinbase|free] [--slippage \
   book|spread|fixed:BPS|regime]\n\
  \                           [--latency-us N] [--maker-fill queue|touch|optimistic]\n\
  \                           [--fees] [--risk-limits] [--compare-risk-limits] [--max-drawdown F]\n\
  \                           [--mc-runs N] [--seed N] [--domains N]\n\
  \                           [--interval 1m] [--bar-interval 1m]\n\
  \                           [--equity-csv PATH] [--blotter-csv PATH]"


let parse_argv () =
  let c = ref default_cli in
  let i = ref 1 in
  let next name =
    if !i + 1 < Array.length Sys.argv then (
      incr i ;
      Sys.argv.(!i))
    else (
      Printf.eprintf "%s requires a value\n" name ;
      exit 2) in
    while !i < Array.length Sys.argv do
      (match Sys.argv.(!i) with
      | "--log" -> c := { !c with log_path = Some (next "--log") }
      | "--y" -> c := { !c with y_symbol = next "--y" }
      | "--x" -> c := { !c with x_symbol = next "--x" }
      | "--capital" -> c := { !c with capital = float_of_string (next "--capital") }
      | "--venue" -> c := { !c with venue_name = next "--venue" }
      | "--slippage" -> c := { !c with slippage = next "--slippage" }
      | "--latency-us" -> c := { !c with latency_us = float_of_string (next "--latency-us") }
      | "--maker-fill" -> c := { !c with maker_fill = next "--maker-fill" }
      | "--fees" -> c := { !c with charge_fees = true }
      | "--risk-limits" -> c := { !c with risk_limits = true }
      | "--mc-runs" -> c := { !c with mc_runs = int_of_string (next "--mc-runs") }
      | "--seed" -> c := { !c with seed = Int64.of_string (next "--seed") }
      | "--domains" -> c := { !c with domains = int_of_string (next "--domains") }
      | "--equity-csv" -> c := { !c with equity_csv = Some (next "--equity-csv") }
      | "--blotter-csv" -> c := { !c with blotter_csv = Some (next "--blotter-csv") }
      | "--compare-risk-limits" -> c := { !c with compare_risk_limits = true }
      | "--max-drawdown" -> c := { !c with max_drawdown = float_of_string (next "--max-drawdown") }
      | "--interval" -> c := { !c with interval_ns = duration_ns (next "--interval") "--interval" }
      | "--bar-interval" ->
        c := { !c with bar_interval_ns = duration_ns (next "--bar-interval") "--bar-interval" }
      | "--help" | "-h" ->
        print_endline usage ;
        exit 0
      | other ->
        Printf.eprintf "unknown argument: %s\n%s\n" other usage ;
        exit 2) ;
      incr i
    done ;
    !c


let venue_of_name = function
  | "binance" -> Venue.binance_spot
  | "coinbase" -> Venue.coinbase_advanced
  | "free" ->
    (* Zero-fee venue, for isolating the effect of everything else. *)
    Venue.create ~name:"free" ~asset_class:Algostream_domain_market.Asset.Crypto
      ~fee_tiers:[ { Venue.maker_bps = 0.0; taker_bps = 0.0; volume_threshold = 0.0 } ]
      ~base_latency_us:0.0 ~supports_iceberg:true ~supports_stop:true ~min_order_size:0.0
  | other ->
    Printf.eprintf "unknown venue: %s (expected binance|coinbase|free)\n" other ;
    exit 2


let slippage_of_name name =
  if String.length name > 6 && String.sub name 0 6 = "fixed:" then
    BT.Slippage.Fixed_bps (float_of_string (String.sub name 6 (String.length name - 6)))
  else
    match name with
    | "book" -> BT.Slippage.Book_walk
    | "spread" -> BT.Slippage.Spread_fraction 1.0
    | "regime" ->
      (* The "with market conditions" model: cross the spread, scaled by the prevailing regime. *)
      BT.Slippage.Regime_scaled
        {
          base = BT.Slippage.Spread_fraction 1.0;
          multipliers = BT.Slippage.default_regime_multipliers;
        }
    | other ->
      Printf.eprintf "unknown slippage model: %s\n" other ;
      exit 2


let maker_fill_of_name = function
  | "queue" -> BT.Fill_engine.Queue_position
  | "touch" -> BT.Fill_engine.Touch_cross
  | "optimistic" -> BT.Fill_engine.Optimistic
  | other ->
    Printf.eprintf "unknown maker-fill model: %s\n" other ;
    exit 2


let pair_id_of c =
  let parse raw =
    match Symbol.parse ~exchange:"binance" ~raw with
    | Some s -> s
    | None ->
      (* Fall back to a synthetic canonical symbol so an unrecognised ticker still runs. *)
      { Symbol.base = raw; quote = "USD"; asset_class = Symbol.Crypto } in
    Pair_id.of_symbols (parse c.y_symbol) (parse c.x_symbol)


let build_config c =
  let venue = venue_of_name c.venue_name in
  let base = BT.Engine.default_config ~venue ~initial_capital:c.capital in
  let latency =
    if c.latency_us <= 0.0 then BT.Latency.zero
    else
      BT.Latency.of_venue
        (Venue.create ~name:venue.Venue.name ~asset_class:venue.Venue.asset_class
           ~fee_tiers:venue.Venue.fee_tiers ~base_latency_us:c.latency_us
           ~supports_iceberg:venue.Venue.supports_iceberg ~supports_stop:venue.Venue.supports_stop
           ~min_order_size:venue.Venue.min_order_size)
        () in
    {
      base with
      BT.Engine.slippage = slippage_of_name c.slippage;
      latency;
      maker_fill = maker_fill_of_name c.maker_fill;
      cost =
        (if c.charge_fees then BT.Cost_model.default_config venue
         else
           {
             (BT.Cost_model.default_config venue) with
             BT.Cost_model.venue =
               Venue.create ~name:"nofee" ~asset_class:venue.Venue.asset_class
                 ~fee_tiers:[ { Venue.maker_bps = 0.0; taker_bps = 0.0; volume_threshold = 0.0 } ]
                 ~base_latency_us:0.0 ~supports_iceberg:true ~supports_stop:true ~min_order_size:0.0;
           });
      risk_limits = (if c.risk_limits then Some Risk_limits.default else None);
      root_seed = c.seed;
      equity_sample_interval_ns = c.interval_ns;
      (* The pairs strategy needs Config.default.corr_window (256) bars before it is ready, so on a
         short capture the bar interval decides whether it ever trades at all. *)
      bar_interval_ns = Some c.bar_interval_ns;
      flatten_at_end = true;
    }


let write_csv path f =
  match path with
  | None -> ()
  | Some p ->
    let oc = open_out p in
      f oc ;
      close_out oc ;
      Printf.printf "wrote %s\n" p


let run_single c data config =
  let result = BT.Engine.run (module PMR) ~params:PMR.default_params ~config ~data in
    print_endline (BT.Result.summary_to_string result) ;
    let nav = BT.Result.nav_curve result in
    let metrics = Perf.Metrics.of_nav ~nav () in
      print_endline "" ;
      print_endline (Perf.Metrics.to_string metrics) ;
      (* Drawdown episodes — depth, decline and recovery per episode — are what a summary
         max-drawdown figure cannot tell you, and nothing in the tree could report them until the
         performance-analytics layer existed. *)
      let eps = Perf.Drawdown_analysis.episodes ~nav () in
        if Array.length eps > 0 then (
          Printf.printf "\ndrawdown episodes (%d, worst 3):\n" (Array.length eps) ;
          Array.iter
            (fun e -> print_endline ("  " ^ Perf.Drawdown_analysis.episode_to_string e))
            (Perf.Drawdown_analysis.worst eps ~n:3)) ;
        let diags = result.BT.Result.strategy_diagnostics in
          if diags <> [] then (
            print_endline "\nstrategy diagnostics:" ;
            List.iter (fun (k, v) -> Printf.printf "  %-22s %.0f\n" k v) diags) ;
          write_csv c.equity_csv (BT.Result.write_equity_csv result) ;
          write_csv c.blotter_csv (BT.Result.write_blotter_csv result) ;
          result


let run_monte_carlo c data config n_runs =
  (* Bootstrap the realized equity curve: the cheap, honest way to ask whether the observed result
     is distinguishable from luck. Engine-level MC over synthetic markets is available through the
     library; it costs about a second per run and is not what a CLI should default to. *)
  let single = BT.Engine.run (module PMR) ~params:PMR.default_params ~config ~data in
  let nav = BT.Result.nav_curve single in
  let returns = Perf.Returns.of_nav ~nav ~kind:Perf.Returns.Simple in
    if Array.length returns < 32 then
      print_endline "\nnot enough return observations for Monte Carlo (need at least 32)"
    else
      let interval = Perf.Returns.infer_interval_ns ~nav in
      let ppy = Perf.Returns.periods_per_year ~interval_ns:interval () in
      let domains = if c.domains > 0 then c.domains else MC.Pool.recommended_domains () in
      let summary =
        MC.Engine.run_paths ~returns ~n_runs ~root_seed:c.seed ~n_domains:domains
          ~periods_per_year:ppy () in
        Printf.printf "\n%s" (MC.Engine.summary_to_string summary) ;
        Printf.printf "  (%d domains; results are identical at any domain count for a given seed)\n"
          domains


(* Paired A/B on ONE captured path: identical data, identical seed, identical strategy — the only
   difference is whether the risk gate is installed. Two full runs rather than a difference of
   summaries, so the comparison includes every path-dependent effect the gate has.

   This answers "what did the limits do on this data", which is one observation, not a distribution.
   run_comparative over synthetic markets is the tool for a distribution; both are reported because
   either alone is misleading. *)
let run_risk_limit_comparison c data config =
  let limits =
    {
      Risk_limits.default with
      Risk_limits.max_drawdown = c.max_drawdown;
      (* Only the drawdown ceiling is under test. Leaving the others at their defaults would let
         concentration or leverage reject orders too, and the difference could not be attributed. *)
      max_daily_loss = 1e9;
      max_leverage = 1e9;
      max_position_concentration = 1e9;
      max_gross_exposure = 1e9;
    } in
  let run risk_limits =
    BT.Engine.run
      (module PMR)
      ~params:PMR.default_params
      ~config:{ config with BT.Engine.risk_limits }
      ~data in
  let off = run None in
  let on = run (Some limits) in
  let m r = Perf.Metrics.of_nav ~nav:(BT.Result.nav_curve r) () in
  let m_off = m off and m_on = m on in
  let rejected = on.BT.Result.counters.BT.Result.n_rejected_by_risk in
  let pct a b = if Float.abs a < 1e-12 then Float.nan else (b -. a) /. Float.abs a *. 100.0 in
    Printf.printf "\n=== risk-limit comparison on this capture ===\n" ;
    Printf.printf "  drawdown ceiling %.1f%%, all other limits disabled\n" (c.max_drawdown *. 100.0) ;
    Printf.printf "  %-18s %12s %12s %12s\n" "" "limits off" "limits on" "change" ;
    Printf.printf "  %-18s %11.2f%% %11.2f%% %11.1f%%\n" "max drawdown"
      (m_off.Perf.Metrics.max_drawdown *. 100.0)
      (m_on.Perf.Metrics.max_drawdown *. 100.0)
      (pct m_off.Perf.Metrics.max_drawdown m_on.Perf.Metrics.max_drawdown) ;
    (* Reported beside the drawdown on purpose: a gate reduces drawdown by trading less, so the
       return it costs is part of the result, not a footnote. *)
    Printf.printf "  %-18s %11.2f%% %11.2f%% %11.1f%%\n" "total return"
      (m_off.Perf.Metrics.total_return *. 100.0)
      (m_on.Perf.Metrics.total_return *. 100.0)
      (pct m_off.Perf.Metrics.total_return m_on.Perf.Metrics.total_return) ;
    Printf.printf "  %-18s %12.3f %12.3f %11.1f%%\n" "sharpe" m_off.Perf.Metrics.sharpe
      m_on.Perf.Metrics.sharpe
      (pct m_off.Perf.Metrics.sharpe m_on.Perf.Metrics.sharpe) ;
    Printf.printf "  %-18s %12.3f %12.3f %11.1f%%\n" "calmar" m_off.Perf.Metrics.calmar
      m_on.Perf.Metrics.calmar
      (pct m_off.Perf.Metrics.calmar m_on.Perf.Metrics.calmar) ;
    Printf.printf "  %-18s %12d %12d\n" "fills" off.BT.Result.counters.BT.Result.n_fills
      on.BT.Result.counters.BT.Result.n_fills ;
    Printf.printf "  %-18s %12s %12d\n" "rejected by risk" "-" rejected ;
    (* A zero here means the gate never bound, so the two arms are the same run and any difference
       reported above would be noise. Saying so is the difference between a result and a number. *)
    if rejected = 0 then
      print_endline
        "\n\
        \  NOTE: the gate never fired on this data, so the arms are identical and the comparison\n\
        \        says nothing about the limits. Lower --max-drawdown or use a path that draws down."


let () =
  let c = parse_argv () in
    match c.log_path with
    | None ->
      Printf.eprintf "--log is required\n%s\n" usage ;
      exit 2
    | Some path ->
      if not (Sys.file_exists path) then (
        Printf.eprintf "no such file: %s\n" path ;
        exit 2) ;
      let data = BT.Data_source.of_event_log ~path ~symbols:[ c.y_symbol; c.x_symbol ] () in
      let config = build_config c in
        Printf.printf "backtest: %s vs %s from %s\n" c.y_symbol c.x_symbol path ;
        Printf.printf "  venue=%s slippage=%s latency=%.0fus maker=%s fees=%b risk_limits=%b\n"
          c.venue_name c.slippage c.latency_us c.maker_fill c.charge_fees c.risk_limits ;
        Printf.printf "  pair=%s seed=%Ld\n\n" (Pair_id.to_string (pair_id_of c)) c.seed ;
        let _ = run_single c data config in
          if c.compare_risk_limits then run_risk_limit_comparison c data config ;
          if c.mc_runs > 0 then run_monte_carlo c data config c.mc_runs
