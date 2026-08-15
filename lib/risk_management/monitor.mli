(** Risk Monitor — top-level facade aggregating drawdown + circuit breaker + correlation breakdown +
    exposures + VaR + risk-limit breach detection.

    Strategies hold a Monitor.t alongside their Portfolio, and feed it the latest snapshot + recent
    returns + any updated pair correlations on each tick or bar. The Monitor publishes a fresh
    {!Risk_snapshot.t} via [Atomic.set] on each [update] so other Domains read race-free. *)

module Portfolio = Algostream_domain_portfolio.Portfolio
module Garch11 = Algostream_advanced_models.Garch11

type stats = {
  n_updates : int;
  n_breaches : int;
  n_circuit_trips : int;
}

type t

val create :
  limits:Risk_limits.t ->
  circuit_config:Circuit_breaker.config ->
  ?initial_equity:float ->
  unit ->
  t

(** Ingest a portfolio snapshot + recent returns + optional correlation feed + optional GARCH state.
    Recomputes VaR / drawdown / exposures / circuit / correlation status, publishes a fresh
    {!Risk_snapshot.t}, and returns the same snapshot. *)
val update :
  t ->
  portfolio:Portfolio.portfolio ->
  returns:float array ->
  ?correlation_updates:(string * string * float) list ->
  ?garch:Garch11.t ->
  ts_ns:int64 ->
  unit ->
  Risk_snapshot.t

val snapshot : t -> Risk_snapshot.t

val snapshot_atomic : t -> Risk_snapshot.t Atomic.t

val circuit_breaker_state : t -> Circuit_breaker.state

val reset_circuit : t -> ts_ns:int64 -> unit

(** Last realized volatility computed during {!update} (sample stddev of [returns]). Feeds
    {!Proprietary_models.compute_score}. *)
val realized_vol : t -> float

(** Baseline volatility — initialized from the first {!update}'s returns, sticky thereafter so vol
    spikes are measured against a stable reference. *)
val baseline_vol : t -> float

val stats : t -> stats
