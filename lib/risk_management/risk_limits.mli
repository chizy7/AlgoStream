(** Configurable risk limits + pre-trade breach detection.

    Pure-function check: callers feed the current portfolio + a proposed order, get back a list of
    {!breach}es (empty when within limits). The new layer never mutates anything — strategies decide
    whether to block the order or proceed.

    {2 Path-dependent limits}

    Drawdown and daily loss cannot be computed from a portfolio snapshot: both need history the
    snapshot does not carry. Rather than give this module state, {!pre_trade_check} takes them as
    scalars and the caller owns the tracking — {!Drawdown.Tracker} already does exactly this, and
    both call sites ({!Algostream_backtest.Engine} and {!Algostream_runtime.Instance}) hold one.

    The thresholds are compared the same way {!Monitor.update} compares them, so the pre-trade gate
    and the monitoring snapshot cannot disagree about whether a limit is breached. *)

module Portfolio = Algostream_domain_portfolio.Portfolio
module Order = Algostream_domain_orders.Order

type t = {
  max_drawdown : float;  (** fractional, positive; gate + {!Monitor} *)
  max_daily_loss : float;  (** fractional, positive; gate + {!Monitor} *)
  max_leverage : float;
  max_var_pct : float;
    (** {!Monitor} only. A VaR gate needs a return distribution, which the pre-trade path does not
        have. *)
  max_position_concentration : float;
  max_gross_exposure : float;  (** gate only *)
  correlation_breakdown_threshold : float;
    (** Passed to {!Correlation_breakdown.Detector} by {!Monitor}. *)
}

val default : t

type breach =
  | Drawdown of {
      current : float;
      limit : float;
    }
  | Daily_loss of {
      current : float;
      limit : float;
    }
  | Leverage of {
      current : float;
      limit : float;
    }
  | Var of {
      current : float;
      limit : float;
    }
  | Position_concentration of {
      symbol : string;
      current : float;
      limit : float;
    }
  | Gross_exposure of {
      current : float;
      limit : float;
    }

(** Breaches for the proposed order, empty when it is within every limit.

    [current_drawdown] is the fractional drop from the running equity peak, positive, as
    {!Drawdown.Tracker.current_drawdown} returns it. [daily_pnl_pct] is a signed fractional return
    over the accounting day, so a loss is negative. Both default to 0.0 — i.e. omitting them
    disables those two checks rather than tripping them. *)
val pre_trade_check :
  t ->
  portfolio:Portfolio.portfolio ->
  proposed_order:Order.order ->
  ?proposed_price:float ->
  ?current_drawdown:float ->
  ?daily_pnl_pct:float ->
  unit ->
  breach list

val breach_to_string : breach -> string
