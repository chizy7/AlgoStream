(** One live strategy, paper-traded.

    {1 Paper trading}

    {b No order ever reaches a venue.} There is no order placement anywhere in this repository — no
    credentials, no request signing, no trading endpoint; the only bytes the ingestion layer ever
    writes to a socket are a subscribe message, a pong and a close. Fills here are simulated against
    live quotes by the same [Backtest.Fill_engine] the offline engine uses, and every P&L figure the
    dashboard shows is therefore hypothetical.

    {1 Why it reuses the backtest machinery}

    [Strategy.S] was written so that a backtest and a live runner could drive the same strategy:
    [on_event] returns [Action.t list] rather than submitting, so order-id assignment, the risk gate
    and routing stay outside it. This module is the live driver that was always intended and never
    built.

    It deliberately reuses [Market_view], [Fill_engine], [Cost_model] and [Slippage] rather than
    growing a parallel execution path. Beyond avoiding duplicate logic, it is what makes the two
    drivers comparable: [test/runtime/test_parity.ml] feeds one strategy the same records through
    this module and through [Backtest.Engine] and asserts they agree.

    {1 Threading}

    An instance is driven by exactly one Domain — the runtime supervisor's drain loop — and its
    internal state is ordinary mutable state. Observers on other Domains read {!snapshot}, which is
    an immutable record published with [Atomic.set]. Control operations ({!pause}, {!resume},
    {!set_allocation}) are safe from any Domain: they set atomics the drain loop reads. *)

module Data_source = Algostream_backtest.Data_source
module Strategy = Algostream_strategy.Strategy
module Venue = Algostream_order_management.Venue
module Slippage = Algostream_backtest.Slippage
module Latency = Algostream_backtest.Latency
module Cost_model = Algostream_backtest.Cost_model
module Fill_engine = Algostream_backtest.Fill_engine
module Risk_limits = Algostream_risk_management.Risk_limits

type config = {
  strategy_id : string;  (** unique within a supervisor; used in ids, blotter rows and the API *)
  symbols : string list;
    (** handed to [Strategy.S.create]. A strategy derives its {!Strategy.subscriptions} from these,
        so leaving it empty means the instance subscribes to nothing and never trades. *)
  initial_capital : float;
  venue : Venue.t;
  slippage : Slippage.model;
  latency : Latency.t;
  cost : Cost_model.config;
  risk_limits : Risk_limits.t option;
  maker_fill : Fill_engine.maker_fill_model;
  stop_trigger : Fill_engine.stop_trigger_ref;
  bar_interval_ns : int64;
    (** cadence for the bar builders that feed [Event.Bar] and the pairs cointegration retest *)
  pairs_config : Algostream_pairs.Config.t;
  seed : int64;  (** seeds latency jitter only; market data is whatever actually arrives *)
  max_recent_fills : int;
  nav_sample_interval_ns : int64;
}

val default_config : strategy_id:string -> venue:Venue.t -> initial_capital:float -> config

type t

(** Build an instance. The strategy's [subscriptions] are read once here to set up bar builders and
    pair state, exactly as [Backtest.Engine] does. *)
val create : (module Strategy.S with type params = 'p) -> params:'p -> config:config -> t

val id : t -> string

val lifecycle : t -> Snapshot.lifecycle

(** Feed one market record. Runs the full step: market view, matching, strategy dispatch, action
    handling, marking. A no-op once stopped.

    While {!Paused} the market view and fill engine still advance — resting orders continue to fill,
    which is what a real paused strategy experiences — but the strategy is not consulted and emits
    no new orders. *)
val on_record : t -> Data_source.record -> unit

val pause : t -> unit

val resume : t -> unit

(** Run [on_stop], cancel every working order, and publish a final snapshot. Idempotent. *)
val stop : t -> unit

(** Capital assigned to this instance. Advisory: it is reported and used by position sizing, not
    enforced by the fill engine. *)
val set_allocation : t -> float -> unit

(** Latest published state. Safe from any Domain. *)
val snapshot : t -> Snapshot.instance

(** NAV samples for charting, oldest first. Bounded ring. *)
val nav_curve : t -> (int64 * float) array
