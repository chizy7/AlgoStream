(** Historical market data for a backtest.

    {b Offline only.} [of_event_log] reads a recorded [Event_log] with [Reader.open_] +
    [Reader.iter], exactly as [bin/bars.ml] does — no [Event_bus], no dispatcher Domain. The
    bus-attached [Event_log.replay] is deliberately not used: it delivers asynchronously and is only
    eventually consistent, so two runs over the same file can interleave differently. A backtest
    that cannot reproduce itself is not a backtest.

    {b One consequence worth knowing.} [Event_log.Reader.iter] is a push fold, not a cursor — there
    is no [next : t -> record option]. So the engine is a step function driven by a fold rather than
    a pull-based k-way merge, and
    {b multi-symbol data must already be time-ordered within a single log}. Merging two
    separately-recorded logs is not supported by {!of_event_log}; use {!of_records}, which
    materializes and sorts, at the cost of holding the stream in memory. Monte Carlo always uses
    {!of_records} because synthetic paths are generated in memory anyway. *)

module Order_book = Algostream_domain_market.Order_book
module Side = Algostream_strategy.Side

type record =
  | Tick of {
      symbol : string;
      ts_ns : int64;
      price : float;
      volume : float;
      bid : float option;
      ask : float option;
    }
  | Trade_print of {
      symbol : string;
      ts_ns : int64;
      price : float;
      size : float;
      aggressor : Side.t option;
    }
    (** A tape print. The fill engine consumes these to decrement queue position on resting limit
        orders — they are what makes maker fills simulable. *)
  | Book of Order_book.order_book

type t

val ts_ns : record -> int64

val symbol : record -> string

(** Read a recorded event log. [symbols] filters (all symbols when absent); [lo_ts_ns] / [hi_ts_ns]
    restrict the time window inclusively. *)
val of_event_log :
  path:string -> ?symbols:string list -> ?lo_ts_ns:int64 -> ?hi_ts_ns:int64 -> unit -> t

(** In-memory records. Sorted by timestamp on construction with a stable sort, so records sharing a
    timestamp keep their input order — which is what makes a synthetic multi-symbol path
    deterministic. *)
val of_records : record array -> t

(** Build from OHLCV bars: each bar becomes one [Tick] at its close timestamp, priced at the close,
    with volume from the bar. The coarsest possible fidelity, and the right default when only bar
    data exists. *)
val of_bars : Algostream_time_series.Bar.t array -> t

(** Concatenate, preserving global time order. *)
val concat : t list -> t

(** Fold over the records in time order. Returns the number delivered. Out-of-order records are
    dropped and counted rather than reordered — matching [Pairs.Processor]'s handling; a backtest
    never rewinds. *)
val iter : t -> f:(record -> unit) -> int

(** Records dropped by the most recent {!iter} for arriving out of order. *)
val out_of_order_dropped : t -> int

(** Materialize to an array. Forces an event-log source to be read fully into memory. *)
val to_array : t -> record array

(** Distinct symbols present, in first-seen order. *)
val symbols : t -> string list
