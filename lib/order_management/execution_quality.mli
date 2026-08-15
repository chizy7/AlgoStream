(** Post-trade execution quality (TCA) report.

    Wraps and extends [Algostream_domain_trades.Trade.Trade_aggregation.execution_quality], which
    already computes slippage and implementation shortfall for a single trade. This module
    aggregates a {b list of fills} for the same order into one report with timing metrics, fill
    rate, VWAP comparison, and IS in basis points. *)

module Order = Algostream_domain_orders.Order

type fill = {
  ts_ns : int64;
  price : float;
  quantity : float;
  venue : string;
  commission : float;
}

type report = {
  decision_price : float;
  total_quantity : float;
  filled_quantity : float;
  fill_rate : float;
  avg_fill_price : float;
  total_commission : float;
  slippage_bps : float;  (** signed: positive = adverse to the order side *)
  vwap_diff_bps : float;  (** signed: positive = adverse vs market VWAP over the fill window *)
  implementation_shortfall_bps : float;  (** [|slippage| + commission_bps] *)
  time_to_full_fill_ns : int64 option;  (** [Some t] iff [fill_rate = 1.0] *)
  first_fill_latency_ns : int64;  (** time from [decision_ts_ns] to the first fill *)
}

val analyze :
  order:Order.order ->
  decision_price:float ->
  decision_ts_ns:int64 ->
  fills:fill list ->
  market_vwap:float ->
  report

val report_to_string : report -> string
