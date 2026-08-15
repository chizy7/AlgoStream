(** Slippage and market impact.

    The heavy lifting already existed: [Order_management.Book_impact.estimate_from_book] walks a
    real book to get an average fill price, and [Book_impact.permanent_impact] implements the
    Almgren square-root model. This module composes them with the conditioning the requirement
    actually asks for — "slippage modeling {i with market conditions}" — rather than writing a
    fourth impact model.

    The market-conditions part is {!Regime_scaled}: the same base model, multiplied by a factor that
    depends on the prevailing [Analytics.Regime.t]. A strategy backtested only against calm-regime
    slippage will look far better than it trades, because the moments it most wants to transact are
    exactly the moments spreads widen and depth evaporates. *)

module Order_book = Algostream_domain_market.Order_book
module Regime = Algostream_analytics.Regime
module Side = Algostream_strategy.Side

(** Everything the models may condition on. Fields are optional because a bar-only backtest knows
    far less than a full-depth one, and a model should degrade rather than fail. *)
type market_ctx = {
  bid : float option;
  ask : float option;
  last : float;
  sigma : float option;  (** per-period return volatility *)
  adv : float option;  (** average daily volume, in units of the instrument *)
  regime : Regime.t option;
  book : Order_book.order_book option;
}

type model =
  | Book_walk
    (** Delegate to [Book_impact.estimate_from_book]. The most faithful option, and the only one
        that can report [unfilled_quantity]. Requires [ctx.book]; falls back to
        [Spread_fraction 1.0] when absent. *)
  | Fixed_bps of float  (** flat cost; the crude baseline worth comparing against *)
  | Spread_fraction of float
    (** pay [f] × half-spread. [f = 1.0] crosses fully; [f = 0.5] is a mid-to-touch assumption *)
  | Volatility_scaled of {
      k : float;
      participation_floor : float;
    }
    (** [k · σ · sqrt(quantity / adv)] — the temporary-impact companion to Almgren's permanent term.
        [participation_floor] bounds the participation rate from below so a tiny order in a thin
        name does not get a free pass. *)
  | Regime_scaled of {
      base : model;
      multipliers : (Regime.t * float) list;
    }
    (** {b The "with market conditions" model.} Scales [base] by the multiplier matching
        [ctx.regime]. Regimes absent from the list use [1.0]. *)
  | Composite of model list  (** additive in bps *)

(** Crisis ×3.0, Volatile ×1.8, Trending ×1.2, Calm ×1.0 — a defensible starting shape, not a
    calibrated result. Calibrate against your own fills before trusting the numbers. *)
val default_regime_multipliers : (Regime.t * float) list

type outcome = {
  executed_price : float;
  filled_quantity : float;
  unfilled_quantity : float;  (** > 0 only when [Book_walk] exhausted the book *)
  slippage_bps : float;  (** signed; positive = adverse to the order's side *)
  levels_consumed : int;
  permanent_impact_bps : float;
    (** Almgren square-root estimate. The engine applies this to the symbol's reference mark so a
        large order genuinely moves the market for subsequent fills. *)
}

(** Estimate the execution of [quantity] on [side] under [model]. Never raises; a model that cannot
    be evaluated with the information in [ctx] degrades to a simpler one. *)
val apply :
  model -> side:Side.t -> quantity:float -> ctx:market_ctx -> ?daily_vol:float -> unit -> outcome

val model_to_string : model -> string
