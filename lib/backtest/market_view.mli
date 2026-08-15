(** Per-symbol market state maintained by the engine.

    Backs the accessor closures in [Strategy.Context.t]. The engine owns this; strategies only ever
    see the closures, so they cannot mutate it.

    Also tracks the two conditioning inputs the slippage model wants — realized volatility and
    average daily volume — and applies permanent impact to the reference mark, so that a large order
    genuinely moves the market for subsequent fills within the same run. *)

module Order_book = Algostream_domain_market.Order_book
module Regime = Algostream_analytics.Regime

type t

val create : ?vol_window:int -> ?adv_window_ns:int64 -> unit -> t

(** Fold a market record into the view. *)
val observe : t -> Data_source.record -> unit

val last_price : t -> string -> float option

val quote : t -> string -> (float * float) option

val book : t -> string -> Order_book.order_book option

val mid : t -> string -> float option

(** Realized volatility of log returns over the trailing window, per observation. [None] until the
    window fills. *)
val sigma : t -> string -> float option

(** Volume observed over the trailing [adv_window_ns], scaled to a daily rate. [None] when too
    little history has accumulated to extrapolate honestly. *)
val adv : t -> string -> float option

(** Current regime label, from a per-symbol [Analytics.Regime] detector driven on observed ticks.
    [None] before the detector has warmed up. *)
val regime : t -> string -> Regime.t option

(** Assemble the context the slippage model consumes. *)
val slippage_ctx : t -> string -> Slippage.market_ctx option

(** Apply a permanent-impact shift to the reference mark, so a large fill moves the price the rest
    of the run trades against. [bps] is signed by the order's side. *)
val apply_permanent_impact : t -> string -> bps:float -> unit

(** Running volume-weighted average price since the run began — the benchmark
    [Execution_quality.analyze] compares fills against. *)
val vwap : t -> string -> float

val symbols : t -> string list
