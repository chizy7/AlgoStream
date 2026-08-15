(** The backtest loop.

    {2 The authoritative clock}

    The engine carries its own [int64] event clock, taken from the data. Every timestamp in
    {!Result.t} comes from it. The [Timestamp.t] fields on [Portfolio] / [Position] / [Trade] are
    populated via the [?ts] parameters and are {b advisory metadata only} — no analytics path reads
    them. That is why the ~240 ns quantization of [Timestamp.of_ns] cannot affect any reported
    number.

    {2 Step ordering}

    Per market record, in this order — the ordering is contract, because changing it changes
    results:

    + advance the event clock; drop and count out-of-order records
    + update {!Market_view}; feed bar builders and per-pair state
    + release inbound messages whose delivery time has arrived (fills, order updates, timers)
    + release outbound orders that have now reached the venue
    + run one {!Fill_engine} matching pass; book each fill into the portfolio and blotter
    + deliver the market event to the strategy; collect its actions
    + gate actions against risk limits, assign order ids, admit them with outbound latency
    + mark to market, accrue financing, and sample the equity curve

    A fill is booked into the portfolio {i before} the strategy is told about it — the portfolio is
    the venue's view, the strategy's view is delayed by inbound latency. That asymmetry is real and
    is what makes a latency-sensitive strategy behave differently here than in a naive simulator.

    {2 Pairs}

    A [Strategy.Pair] subscription causes the engine to drive a [Pairs.Per_pair.t] inline and emit
    [Event.Pair_snapshot]. [Pairs.Processor] is deliberately bypassed: its Domain, SPSC queue and
    bus subscription are eventual-consistency machinery that would make results depend on
    scheduling. This mirrors what [test/pairs/test_determinism.ml] already does. *)

module Portfolio = Algostream_domain_portfolio.Portfolio
module Venue = Algostream_order_management.Venue
module Risk_limits = Algostream_risk_management.Risk_limits
module Rng = Algostream_rng.Rng

type config = {
  initial_capital : float;
  account_id : string;
  venue : Venue.t;
  slippage : Slippage.model;
  latency : Latency.t;
  cost : Cost_model.config;
  risk_limits : Risk_limits.t option;  (** [None] disables the pre-trade gate *)
  maker_fill : Fill_engine.maker_fill_model;
  stop_trigger : Fill_engine.stop_trigger_ref;
  equity_sample_interval_ns : int64;  (** [0L] samples on every event *)
  pairs_config : Algostream_pairs.Config.t;
  bar_interval_ns : int64 option;  (** emit [Event.Bar] at this cadence when set *)
  root_seed : int64;
  run_index : int;
  flatten_at_end : bool;
  max_events : int option;
}

(** Zero latency, book-walk slippage, queue-position maker fills, no risk gate, equity sampled every
    event. A deliberately frictionless starting point — add costs explicitly so that what you are
    assuming is visible in the config rather than buried in a default. *)
val default_config : venue:Venue.t -> initial_capital:float -> config

(** Run a strategy over historical data.

    Randomness comes from two disjoint substreams of [root_seed]: index [2·run_index] drives
    anything data-related, index [2·run_index + 1] drives execution noise (latency jitter). Keeping
    them separate means changing the execution model does not shift the price path — common random
    numbers, which is what makes A/B comparisons across model variants low-variance. *)
val run :
  (module Algostream_strategy.Strategy.S with type params = 'p) ->
  params:'p ->
  config:config ->
  data:Data_source.t ->
  Result.t
