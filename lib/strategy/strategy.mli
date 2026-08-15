(** The strategy contract.

    The layers below produce every ingredient of a statistical-arbitrage decision — cointegration,
    spread z-scores, hedge ratios, GARCH, VaR — but nothing that {i decided} anything.
    [Pairs.Snapshot.signal] was computed, published, and read by exactly one caller:
    [Snapshot.to_string], which printed it. This module type is where the decision goes.

    {b Deliberately dependency-light.} [algostream.strategy] does not depend on
    [algostream.backtest], and it does not depend on [algostream.infrastructure.event_bus]. A live
    runner can therefore implement against [S] without linking the fill simulator, and the backtest
    can drive it without an event bus. That is the whole reason this is its own library.

    {b Rules an implementation must honour.} These are contract, not style:

    - {b No clocks.} Read time from [ctx.ts_ns]. [lib/strategy] is on the wall-clock lint list, so
      [Clock.now_*], [Unix.gettimeofday] and [Timestamp.now] all fail CI here.
    - {b No I/O, no Domains, no bus.} [on_event] is called inside the engine's inner loop.
    - {b Idempotence.} [on_event] may be called with the same logical signal repeatedly — a z-score
      stays past its entry band for many ticks. Track what you have already acted on in [state] and
      return [[]] the second time, or the engine will submit an order per tick.
    - {b Mutation of [state] is expected}; mutation of anything reachable through [ctx] is not.

    Every tunable is a [float] and must be reachable through {!params_of_assoc} /
    {!params_to_assoc}, because that pair is how [algostream.optimization] moves through the
    parameter space without knowing the concrete [params] type. An integer dimension is a float with
    an integrality check inside [params_of_assoc]. A parameter not reachable that way is a parameter
    the optimizer cannot tune. *)

(** What market data the engine must feed this strategy. *)
type subscription =
  | Symbol of string
  | Bars of {
      symbol : string;
      interval_ns : int64;
    }
  | Pair of {
      pair : Algostream_pairs.Pair_id.t;
      y_symbol : string;
      x_symbol : string;
    }
    (** The engine drives a [Pairs.Per_pair.t] inline for this pair and emits [Event.Pair_snapshot].
    *)
  | Timer_every of {
      interval_ns : int64;
      tag : string;
    }

module type S = sig
  val name : string

  val version : string

  (** {2 Parameters} *)

  type params

  val default_params : params

  (** Validate and build [params] from the optimizer's flat representation. Return [Error] with a
      human-readable reason rather than clamping silently — a search that quietly clamps reports
      scores for points it never actually evaluated. *)
  val params_of_assoc : (string * float) list -> (params, string) Stdlib.result

  val params_to_assoc : params -> (string * float) list

  (** [(name, lo, hi)] per tunable dimension. [algostream.optimization] builds its default search
      space from this. *)
  val param_bounds : (string * float * float) list

  (** {2 Lifecycle} *)

  type state

  val create : params:params -> symbols:string list -> state

  val subscriptions : state -> subscription list

  (** The callback. Returns the actions the strategy wants taken; the engine gates them against risk
      limits, assigns order ids, applies latency and routes them. *)
  val on_event : state -> Context.t -> Event.t -> Action.t list

  (** Called once after the last market event. Emit flattening orders here if the strategy wants to
      end flat; the engine can also flatten unconditionally via its own config. *)
  val on_stop : state -> Context.t -> Action.t list

  (** Free-form counters surfaced in the backtest result — signals generated, entries skipped by a
      screen, and so on. Invaluable when a strategy does nothing and you need to know which gate
      closed. *)
  val diagnostics : state -> (string * float) list
end

(** First-class packed strategy, for code that holds a heterogeneous collection. *)
type packed = (module S)

(** {2 Helpers for implementations} *)

(** Look up a required parameter, returning a uniform error message when absent. *)
val require : (string * float) list -> string -> (float, string) Stdlib.result

(** As {!require}, plus an inclusive range check. *)
val require_in :
  (string * float) list -> string -> lo:float -> hi:float -> (float, string) Stdlib.result

(** As {!require}, plus a check that the value is integral. *)
val require_int : (string * float) list -> string -> (int, string) Stdlib.result
