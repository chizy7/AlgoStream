module Side = Algostream_strategy.Side
module Trade = Algostream_domain_trades.Trade
module Risk_snapshot = Algostream_risk_management.Risk_snapshot

type lifecycle =
  | Running
  | Paused
  | Stopped

let lifecycle_to_string = function
  | Running -> "running"
  | Paused -> "paused"
  | Stopped -> "stopped"


type position = {
  symbol : string;
  quantity : float;
  average_price : float;
  market_value : float;
  unrealized_pnl : float;
}

type fill = {
  ts_ns : int64;
  order_id : string;
  client_order_id : string;
  symbol : string;
  side : Side.t;
  quantity : float;
  price : float;
  commission : float;
  liquidity : Trade.execution_type;
  tag : string;
}

type instance = {
  strategy_id : string;
  strategy_name : string;
  strategy_version : string;
  lifecycle : lifecycle;
  allocation : float;
  nav : float;
  cash : float;
  realized_pnl : float;
  unrealized_pnl : float;
  gross_exposure : float;
  net_exposure : float;
  leverage : float;
  positions : position list;
  working_orders : int;
  n_events : int;
  n_actions : int;
  n_submitted : int;
  n_rejected_by_risk : int;
  n_fills : int;
  recent_fills : fill list;
  diagnostics : (string * float) list;
  params : (string * float) list;
  last_event_ts_ns : int64;
  risk : Risk_snapshot.t option;
}

type t = {
  ts_ns : int64;
  instances : instance list;
  total_nav : float;
  total_allocation : float;
  n_events : int;
  n_dropped_full_queue : int;
}

let empty =
  {
    ts_ns = 0L;
    instances = [];
    total_nav = 0.0;
    total_allocation = 0.0;
    n_events = 0;
    n_dropped_full_queue = 0;
  }


let to_assoc t =
  let top =
    [
      ("total_nav", t.total_nav);
      ("total_allocation", t.total_allocation);
      ("instances", float_of_int (List.length t.instances));
      ("events", float_of_int t.n_events);
      ("dropped_full_queue", float_of_int t.n_dropped_full_queue);
    ] in
  let per =
    List.concat_map
      (fun i ->
        let p k v = (Printf.sprintf "%s.%s" i.strategy_id k, v) in
          [
            p "nav" i.nav;
            p "cash" i.cash;
            p "realized_pnl" i.realized_pnl;
            p "unrealized_pnl" i.unrealized_pnl;
            p "gross_exposure" i.gross_exposure;
            p "net_exposure" i.net_exposure;
            p "leverage" i.leverage;
            p "allocation" i.allocation;
            p "positions" (float_of_int (List.length i.positions));
            p "working_orders" (float_of_int i.working_orders);
            p "events" (float_of_int i.n_events);
            p "actions" (float_of_int i.n_actions);
            p "submitted" (float_of_int i.n_submitted);
            p "rejected_by_risk" (float_of_int i.n_rejected_by_risk);
            p "fills" (float_of_int i.n_fills);
            p "running" (match i.lifecycle with Running -> 1.0 | _ -> 0.0);
          ]
          @ List.map (fun (k, v) -> p ("diag." ^ k) v) i.diagnostics)
      t.instances in
    top @ per


let instance_to_string i =
  Printf.sprintf "%s [%s] nav=%.2f cash=%.2f rpnl=%.2f upnl=%.2f pos=%d work=%d fills=%d rej=%d"
    i.strategy_id (lifecycle_to_string i.lifecycle) i.nav i.cash i.realized_pnl i.unrealized_pnl
    (List.length i.positions) i.working_orders i.n_fills i.n_rejected_by_risk


let to_string t =
  let b = Buffer.create 512 in
    Buffer.add_string b
      (Printf.sprintf "runtime: %d instance(s) nav=%.2f events=%d dropped=%d\n"
         (List.length t.instances) t.total_nav t.n_events t.n_dropped_full_queue) ;
    List.iter (fun i -> Buffer.add_string b ("  " ^ instance_to_string i ^ "\n")) t.instances ;
    Buffer.contents b
