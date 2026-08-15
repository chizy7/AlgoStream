(** P&L attribution over a trade blotter, and the gross-to-net cost waterfall.

    {b Scope, stated plainly.} This is {i not} Brinson allocation/selection/interaction attribution.
    Brinson needs benchmark weights per group per period, a concept this system does not have. What
    is implemented is (a) grouped P&L contributions — by symbol, side, liquidity, regime, holding
    period — and (b) a decomposition of gross P&L down to net through commission, slippage and
    financing. For a single-strategy statistical-arbitrage book that is the attribution that
    actually informs decisions; calling it Brinson would be a misrepresentation.

    The blotter type is defined here rather than imported so that [algostream.performance] does not
    depend on [algostream.backtest] — metrics stay usable against a live portfolio's fill history.
    The backtest engine supplies an adapter. *)

type fill = {
  ts_ns : int64;
  symbol : string;
  signed_quantity : float;  (** positive = buy, negative = sell *)
  price : float;
  commission : float;
  slippage_cost : float;  (** currency, vs the decision price; positive = adverse *)
  financing_cost : float;
  is_maker : bool;
  strategy_id : string;
  realized_pnl_after : float;  (** portfolio cumulative realized P&L after this fill *)
}

type contribution = {
  key : string;
  realized_pnl : float;
  commission : float;
  slippage_cost : float;
  financing_cost : float;
  net_pnl : float;  (** [realized_pnl - commission - slippage - financing] *)
  gross_notional : float;
  n_fills : int;
  pct_of_net : float;  (** signed share of the total net P&L *)
}

(** Grouped contributions, sorted by [|net_pnl|] descending. *)
val by_symbol : fill array -> contribution array

val by_strategy : fill array -> contribution array

(** Two groups: ["buy"] and ["sell"]. *)
val by_side : fill array -> contribution array

(** Two groups: ["maker"] and ["taker"]. Reveals whether the edge survives paying the taker fee — a
    decisive question for a high-turnover book. *)
val by_liquidity : fill array -> contribution array

(** [by_regime fills ~regimes] attributes each fill to the most recent regime label at or before its
    timestamp. [regimes] must be sorted ascending by timestamp. Fills before the first label are
    grouped under ["unlabelled"]. *)
val by_regime :
  fill array -> regimes:(int64 * Algostream_analytics.Regime.t) array -> contribution array

(** [by_holding_bucket fills ~buckets_ns] groups by how long the position that a fill closed was
    held. Buckets are upper bounds in nanoseconds, ascending; anything above the last bucket lands
    in an overflow group. *)
val by_holding_bucket : fill array -> buckets_ns:int64 array -> contribution array

type waterfall = {
  gross_pnl : float;
  commission : float;
  slippage : float;
  financing : float;
  net_pnl : float;
  cost_ratio : float;  (** total costs / |gross_pnl| — how much of the edge the frictions eat *)
}

val cost_waterfall : fill array -> waterfall

val contribution_to_string : contribution -> string

val waterfall_to_string : waterfall -> string
