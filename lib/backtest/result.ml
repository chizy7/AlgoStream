module Portfolio = Algostream_domain_portfolio.Portfolio
module Trade = Algostream_domain_trades.Trade
module Execution_quality = Algostream_order_management.Execution_quality
module Side = Algostream_strategy.Side
module Attribution = Algostream_performance.Attribution

type equity_point = {
  ts_ns : int64;
  nav : float;
  cash : float;
  gross_exposure : float;
  net_exposure : float;
  leverage : float;
  drawdown : float;
  n_positions : int;
}

type blotter_row = {
  ts_ns : int64;
  order_id : string;
  client_order_id : string;
  symbol : string;
  side : Side.t;
  quantity : float;
  price : float;
  notional : float;
  commission : float;
  slippage_cost : float;
  liquidity : Trade.execution_type;
  strategy_id : string;
  tag : string;
  nav_after : float;
  realized_pnl_after : float;
}

type counters = {
  n_events : int;
  n_out_of_order_dropped : int;
  n_actions : int;
  n_submitted : int;
  n_rejected_by_risk : int;
  n_fills : int;
  n_maker_fills : int;
  n_taker_fills : int;
  n_cancelled : int;
  n_expired : int;
  n_fok_killed : int;
  n_ioc_remainder_cancelled : int;
  n_stops_triggered : int;
  unfilled_quantity : float;
}

type t = {
  strategy_name : string;
  params : (string * float) list;
  root_seed : int64;
  run_index : int;
  equity : equity_point array;
  blotter : blotter_row array;
  tca : (string * Execution_quality.report) array;
  final_portfolio : Portfolio.portfolio;
  counters : counters;
  first_ts_ns : int64;
  last_ts_ns : int64;
  total_commission : float;
  total_financing : float;
  strategy_diagnostics : (string * float) list;
}

let empty_counters =
  {
    n_events = 0;
    n_out_of_order_dropped = 0;
    n_actions = 0;
    n_submitted = 0;
    n_rejected_by_risk = 0;
    n_fills = 0;
    n_maker_fills = 0;
    n_taker_fills = 0;
    n_cancelled = 0;
    n_expired = 0;
    n_fok_killed = 0;
    n_ioc_remainder_cancelled = 0;
    n_stops_triggered = 0;
    unfilled_quantity = 0.0;
  }


let nav_curve t = Array.map (fun (e : equity_point) -> (e.ts_ns, e.nav)) t.equity

let to_perf_fills t =
  let total_notional = Array.fold_left (fun a r -> a +. Float.abs r.notional) 0.0 t.blotter in
    Array.map
      (fun r ->
        (* Financing accrues on carried exposure, not on any one fill, so there is no correct
           per-fill attribution. Pro rata by notional is the least-bad approximation and is called
           out as an approximation rather than presented as measured. *)
        let share = if total_notional <= 0.0 then 0.0 else Float.abs r.notional /. total_notional in
          {
            Attribution.ts_ns = r.ts_ns;
            symbol = r.symbol;
            signed_quantity = Side.signed r.side ~qty:r.quantity;
            price = r.price;
            commission = r.commission;
            slippage_cost = r.slippage_cost;
            financing_cost = t.total_financing *. share;
            is_maker = (match r.liquidity with Trade.Maker -> true | _ -> false);
            strategy_id = r.strategy_id;
            realized_pnl_after = r.realized_pnl_after;
          })
      t.blotter


let equity_csv_header = "ts_ns,nav,cash,gross_exposure,net_exposure,leverage,drawdown,n_positions"

let write_equity_csv t oc =
  output_string oc (equity_csv_header ^ "\n") ;
  Array.iter
    (fun (e : equity_point) ->
      Printf.fprintf oc "%Ld,%.8f,%.8f,%.8f,%.8f,%.6f,%.8f,%d\n" e.ts_ns e.nav e.cash
        e.gross_exposure e.net_exposure e.leverage e.drawdown e.n_positions)
    t.equity


(* RFC 4180 quoting. [strategy_id] and [tag] are strategy-supplied free text — [tag] exists so a
   fill can be traced back to the reason it was placed — so a comma or newline in either used to
   shift every later column by one and silently corrupt the file. Duplicated rather than taken from
   [Algostream_reporting.Export] because reporting depends on this library, not the other way
   round. *)
let csv_escape s =
  let needs =
    let n = String.length s in
    let rec go i =
      if i >= n then false else match s.[i] with ',' | '"' | '\n' | '\r' -> true | _ -> go (i + 1)
    in
      go 0 in
    if not needs then s
    else
      let b = Buffer.create (String.length s + 8) in
        Buffer.add_char b '"' ;
        String.iter (fun c -> if c = '"' then Buffer.add_string b "\"\"" else Buffer.add_char b c) s ;
        Buffer.add_char b '"' ;
        Buffer.contents b


let blotter_csv_header =
  "ts_ns,order_id,client_order_id,symbol,side,quantity,price,notional,commission,slippage_cost,liquidity,strategy_id,tag,nav_after,realized_pnl_after"


let liquidity_to_string = function
  | Trade.Maker -> "maker"
  | Trade.Taker -> "taker"
  | Trade.Self_trade -> "self"


let write_blotter_csv t oc =
  output_string oc (blotter_csv_header ^ "\n") ;
  Array.iter
    (fun (r : blotter_row) ->
      Printf.fprintf oc "%Ld,%s,%s,%s,%s,%.8f,%.8f,%.8f,%.8f,%.8f,%s,%s,%s,%.8f,%.8f\n" r.ts_ns
        (csv_escape r.order_id) (csv_escape r.client_order_id) (csv_escape r.symbol)
        (Side.to_string r.side) r.quantity r.price r.notional r.commission r.slippage_cost
        (liquidity_to_string r.liquidity) (csv_escape r.strategy_id) (csv_escape r.tag) r.nav_after
        r.realized_pnl_after)
    t.blotter


let summary_to_string t =
  let c = t.counters in
  let start_nav = if Array.length t.equity > 0 then t.equity.(0).nav else 0.0 in
  let end_nav =
    if Array.length t.equity > 0 then t.equity.(Array.length t.equity - 1).nav else 0.0 in
  let ret = if start_nav > 0.0 then (end_nav /. start_nav) -. 1.0 else 0.0 in
    Printf.sprintf
      "%s (seed=%Ld run=%d)\n\
      \  events=%d dropped=%d actions=%d submitted=%d rejected=%d\n\
      \  fills=%d (maker=%d taker=%d) cancelled=%d expired=%d fok=%d ioc=%d stops=%d\n\
      \  unfilled_qty=%.6g commission=%.2f financing=%.2f\n\
      \  NAV %.2f -> %.2f (%.2f%%) over %d equity points"
      t.strategy_name t.root_seed t.run_index c.n_events c.n_out_of_order_dropped c.n_actions
      c.n_submitted c.n_rejected_by_risk c.n_fills c.n_maker_fills c.n_taker_fills c.n_cancelled
      c.n_expired c.n_fok_killed c.n_ioc_remainder_cancelled c.n_stops_triggered c.unfilled_quantity
      t.total_commission t.total_financing start_nav end_nav (ret *. 100.0) (Array.length t.equity)
