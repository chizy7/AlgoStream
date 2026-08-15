(** What a backtest produces.

    Three views of the same run: an equity curve (what happened to capital), a blotter (what was
    traded), and per-order TCA (how well it was executed). [Algostream_performance] consumes the
    first two; {!to_perf_fills} adapts the blotter into that library's input type so the dependency
    runs one way only — [performance] never depends on [backtest]. *)

module Portfolio = Algostream_domain_portfolio.Portfolio
module Trade = Algostream_domain_trades.Trade
module Execution_quality = Algostream_order_management.Execution_quality
module Side = Algostream_strategy.Side

type equity_point = {
  ts_ns : int64;
  nav : float;
  cash : float;
  gross_exposure : float;
  net_exposure : float;
  leverage : float;
  drawdown : float;  (** fractional, from the running peak *)
  n_positions : int;
}

type blotter_row = {
  ts_ns : int64;
  order_id : string;
  client_order_id : string;
  symbol : string;
  side : Side.t;
  quantity : float;  (** positive; direction is in [side] *)
  price : float;
  notional : float;
  commission : float;
  slippage_cost : float;  (** currency, versus the decision price; positive = adverse *)
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

val empty_counters : counters

(** NAV curve in the shape [Algostream_performance] expects. *)
val nav_curve : t -> (int64 * float) array

(** Adapt the blotter into [Performance.Attribution.fill] records. Financing is not attributable to
    an individual fill, so it is spread across fills pro rata by notional — an approximation, and
    noted as one. *)
val to_perf_fills : t -> Algostream_performance.Attribution.fill array

val equity_csv_header : string

val write_equity_csv : t -> out_channel -> unit

val blotter_csv_header : string

val write_blotter_csv : t -> out_channel -> unit

val summary_to_string : t -> string
