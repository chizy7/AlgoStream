(** Transaction costs: exchange fees, and financing on carried positions.

    [Venue.effective_fee_bps], like [base_latency_us], is called by nothing. This module is its
    first consumer and the only producer of [Trade.commission] in a backtest.

    Fee tiers are volume-dependent, so the model is {b stateful}: it accumulates realized notional
    and rolls forward through the venue's tier table as the backtest trades. A strategy that starts
    on the retail tier and works down to the top tier will see its costs fall over the run, which is
    the behaviour that matters when deciding whether an edge survives at achievable volume. *)

module Venue = Algostream_order_management.Venue
module Portfolio = Algostream_domain_portfolio.Portfolio
module Trade = Algostream_domain_trades.Trade

type t

type config = {
  venue : Venue.t;
  extra_fee_bps : float;  (** anything the venue schedule does not cover: clearing, regulatory *)
  min_commission : float;  (** per-fill floor in quote currency *)
  borrow_bps_per_day : float;  (** financing charged on short notional *)
  funding_bps_per_day : float;  (** perpetual-swap funding on gross notional; 0 for spot *)
  initial_monthly_volume : float;  (** starting point on the venue's tier ladder *)
}

val default_config : Venue.t -> config

val create : config -> t

(** Commission for one fill. Applies [Venue.effective_fee_bps] at the accumulated volume, adds
    [extra_fee_bps], and floors the result at [min_commission]. *)
val commission : t -> notional:float -> liquidity:Trade.execution_type -> float

(** Record a fill's notional so the tier ladder advances. Call after {!commission}, so a single fill
    is priced at the tier it actually executed under rather than the one it pushes you into. *)
val observe_fill : t -> notional:float -> unit

(** Financing accrued between two event timestamps: [borrow_bps_per_day] on short exposure plus
    [funding_bps_per_day] on gross. Returns a positive cost. *)
val accrue_financing :
  t -> portfolio:Portfolio.portfolio -> prev_ts_ns:int64 -> now_ns:int64 -> float

val monthly_volume : t -> float

val total_commission : t -> float

val total_financing : t -> float

(** Effective fee in bps at the current accumulated volume — for reporting which tier a run ended
    on. *)
val current_fee_bps : t -> taker:bool -> float
