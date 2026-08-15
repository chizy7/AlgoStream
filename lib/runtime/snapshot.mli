(** What the runtime publishes for observers.

    Every value here is immutable and self-contained, so it can be read from any Domain via
    [Atomic.get] and serialized without touching the live strategy state. The runtime Domain is the
    only writer. *)

module Side = Algostream_strategy.Side
module Trade = Algostream_domain_trades.Trade
module Risk_snapshot = Algostream_risk_management.Risk_snapshot

type lifecycle =
  | Running
  | Paused  (** events still update market state; the strategy is not consulted and emits nothing *)
  | Stopped

val lifecycle_to_string : lifecycle -> string

type position = {
  symbol : string;
  quantity : float;  (** signed *)
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
  allocation : float;  (** capital assigned to this instance *)
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
  recent_fills : fill list;  (** newest first, bounded *)
  diagnostics : (string * float) list;  (** whatever [Strategy.S.diagnostics] reports *)
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

val empty : t

(** Flat numeric view, prefixed per instance. Feeds the telemetry collector's provider interface. *)
val to_assoc : t -> (string * float) list

val instance_to_string : instance -> string

val to_string : t -> string
