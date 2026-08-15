module Metrics = Algostream_performance.Metrics
module Drawdown_analysis = Algostream_performance.Drawdown_analysis
module Attribution = Algostream_performance.Attribution
module Risk_snapshot = Algostream_risk_management.Risk_snapshot
module Risk_limits = Algostream_risk_management.Risk_limits
module Circuit_breaker = Algostream_risk_management.Circuit_breaker
module Correlation_breakdown = Algostream_risk_management.Correlation_breakdown
module Var = Algostream_risk_management.Var
module Runtime_snapshot = Algostream_runtime.Snapshot
module RS = Algostream_runtime.Snapshot
module Side = Algostream_strategy.Side
module Trade = Algostream_domain_trades.Trade
open Export

type table = {
  title : string;
  headers : string list;
  rows : Export.value list list;
}

let render t fmt = Export.render fmt ~headers:t.headers ~rows:t.rows

let table_to_string t =
  let b = Buffer.create 1024 in
    Buffer.add_string b (t.title ^ "\n") ;
    Buffer.add_string b (String.concat " | " t.headers ^ "\n") ;
    List.iter
      (fun row -> Buffer.add_string b (String.concat " | " (List.map value_to_csv row) ^ "\n"))
      t.rows ;
    Buffer.contents b


let liquidity_str = function
  | Trade.Maker -> "maker"
  | Trade.Taker -> "taker"
  | Trade.Self_trade -> "self_trade"


(* ───────────────────────── reports ───────────────────────── *)

let performance ~nav ?periods_per_year () =
  let m =
    match periods_per_year with
    | Some p -> Metrics.of_returns ~returns:[||] ~periods_per_year:p ()
    | None -> Metrics.of_nav ~nav () in
    {
      title = "Performance";
      headers = [ "metric"; "value" ];
      rows = Array.to_list (Array.map (fun (k, v) -> [ S k; F v ]) (Metrics.to_assoc m));
    }


let drawdowns ~nav ?min_depth () =
  let eps = Drawdown_analysis.episodes ~nav ?min_depth () in
    {
      title = "Drawdown episodes";
      headers =
        [
          "index";
          "peak_ts_ns";
          "trough_ts_ns";
          "recovery_ts_ns";
          "peak_equity";
          "trough_equity";
          "depth";
          "decline_ns";
          "recovery_ns";
          "underwater_ns";
        ];
      rows =
        Array.to_list
          (Array.map
             (fun (e : Drawdown_analysis.episode) ->
               [
                 I e.Drawdown_analysis.index;
                 I64 e.Drawdown_analysis.peak_ts_ns;
                 I64 e.Drawdown_analysis.trough_ts_ns;
                 (match e.Drawdown_analysis.recovery_ts_ns with Some t -> I64 t | None -> S "");
                 F e.Drawdown_analysis.peak_equity;
                 F e.Drawdown_analysis.trough_equity;
                 F e.Drawdown_analysis.depth;
                 I64 e.Drawdown_analysis.decline_ns;
                 (match e.Drawdown_analysis.recovery_ns with Some t -> I64 t | None -> S "");
                 I64 e.Drawdown_analysis.underwater_ns;
               ])
             eps);
    }


let risk (r : Risk_snapshot.t) =
  let breaches =
    match r.Risk_snapshot.breaches with
    | [] -> "none"
    | xs -> String.concat "; " (List.map Risk_limits.breach_to_string xs) in
    {
      title = "Risk";
      headers = [ "metric"; "value" ];
      rows =
        [
          [ S "ts_ns"; I64 r.Risk_snapshot.ts_ns ];
          [ S "portfolio_value"; F r.Risk_snapshot.portfolio_value ];
          [ S "var_pct"; F r.Risk_snapshot.var_pct ];
          [ S "var_dollars"; F r.Risk_snapshot.var_dollars ];
          [ S "expected_shortfall_pct"; F r.Risk_snapshot.expected_shortfall_pct ];
          [ S "expected_shortfall_dollars"; F r.Risk_snapshot.expected_shortfall_dollars ];
          [ S "current_drawdown"; F r.Risk_snapshot.current_drawdown ];
          [ S "max_drawdown"; F r.Risk_snapshot.max_drawdown ];
          [ S "peak_equity"; F r.Risk_snapshot.peak_equity ];
          [ S "time_under_water_ns"; I64 r.Risk_snapshot.time_under_water_ns ];
          [ S "gross_exposure"; F r.Risk_snapshot.gross_exposure ];
          [ S "net_exposure"; F r.Risk_snapshot.net_exposure ];
          [ S "leverage_ratio"; F r.Risk_snapshot.leverage_ratio ];
          [ S "largest_position_pct"; F r.Risk_snapshot.largest_position_pct ];
          [ S "n_positions"; I r.Risk_snapshot.n_positions ];
          [
            S "correlation_status";
            S (Correlation_breakdown.status_to_string r.Risk_snapshot.correlation_status);
          ];
          [
            S "circuit_breaker";
            S (Circuit_breaker.state_to_string r.Risk_snapshot.circuit_breaker_state);
          ];
          [ S "breaches"; S breaches ];
          [ S "ready"; B r.Risk_snapshot.ready ];
        ];
    }


let attribution contribs ~title =
  {
    title;
    headers =
      [
        "key";
        "realized_pnl";
        "commission";
        "slippage_cost";
        "financing_cost";
        "net_pnl";
        "gross_notional";
        "n_fills";
        "pct_of_net";
      ];
    rows =
      Array.to_list
        (Array.map
           (fun (c : Attribution.contribution) ->
             [
               S c.Attribution.key;
               F c.Attribution.realized_pnl;
               F c.Attribution.commission;
               F c.Attribution.slippage_cost;
               F c.Attribution.financing_cost;
               F c.Attribution.net_pnl;
               F c.Attribution.gross_notional;
               I c.Attribution.n_fills;
               F c.Attribution.pct_of_net;
             ])
           contribs);
  }


let positions (s : RS.t) =
  {
    title = "Positions";
    headers =
      [ "strategy_id"; "symbol"; "quantity"; "average_price"; "market_value"; "unrealized_pnl" ];
    rows =
      List.concat_map
        (fun (i : RS.instance) ->
          List.map
            (fun (p : RS.position) ->
              [
                S i.RS.strategy_id;
                S p.RS.symbol;
                F p.RS.quantity;
                F p.RS.average_price;
                F p.RS.market_value;
                F p.RS.unrealized_pnl;
              ])
            i.RS.positions)
        s.RS.instances;
  }


let fill_rows ?(audit = false) (s : RS.t) =
  List.concat_map
    (fun (i : RS.instance) ->
      List.map
        (fun (f : RS.fill) ->
          let base =
            [
              I64 f.RS.ts_ns;
              S i.RS.strategy_id;
              S f.RS.symbol;
              S (Side.to_string f.RS.side);
              F f.RS.quantity;
              F f.RS.price;
              F f.RS.commission;
              S (liquidity_str f.RS.liquidity);
            ] in
            if audit then base @ [ S f.RS.order_id; S f.RS.client_order_id; S f.RS.tag; S "paper" ]
            else base @ [ S f.RS.tag ])
        i.RS.recent_fills)
    s.RS.instances


let fills s =
  {
    title = "Fills";
    headers =
      [
        "ts_ns";
        "strategy_id";
        "symbol";
        "side";
        "quantity";
        "price";
        "commission";
        "liquidity";
        "tag";
      ];
    rows = fill_rows s;
  }


let audit_trail s =
  {
    title = "Audit trail (paper — not certified for any regulatory regime)";
    headers =
      [
        "ts_ns";
        "strategy_id";
        "symbol";
        "side";
        "quantity";
        "price";
        "commission";
        "liquidity";
        "order_id";
        "client_order_id";
        "tag";
        "execution_mode";
      ];
    rows = fill_rows ~audit:true s;
  }


let runtime_summary (s : RS.t) =
  {
    title = "Runtime summary";
    headers = [ "metric"; "value" ];
    rows = List.map (fun (k, v) -> [ S k; F v ]) (RS.to_assoc s);
  }


let names = [ "performance"; "drawdowns"; "risk"; "positions"; "fills"; "audit"; "summary" ]

let by_name name ~runtime ~risk_snapshot =
  (* Every instance keeps its own NAV curve; for a portfolio-level report the caller should pass a
     combined one. Reports that need a curve use the runtime's aggregate NAV over time, which the
     supervisor does not retain — so they are computed from the per-instance curves the daemon
     supplies instead. Here they operate on an empty curve and report nothing rather than inventing
     data. *)
  match name with
  | "performance" -> Ok (performance ~nav:[||] ())
  | "drawdowns" -> Ok (drawdowns ~nav:[||] ())
  | "risk" ->
    (match risk_snapshot with
    | Some r -> Ok (risk r)
    | None -> Error "no risk snapshot available — the runtime has no risk monitor attached")
  | "positions" -> Ok (positions runtime)
  | "fills" -> Ok (fills runtime)
  | "audit" -> Ok (audit_trail runtime)
  | "summary" -> Ok (runtime_summary runtime)
  | other ->
    Error
      (Printf.sprintf "unknown report %S (expected one of: %s)" other (String.concat ", " names))
