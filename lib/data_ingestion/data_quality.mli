(** Real-time market-data quality monitors.

    Sequence-gap detection is parser-side: it runs BEFORE the bus publish so a backpressure-driven
    [try_publish] drop cannot cause a false-positive gap alert downstream. Stale-tick and
    crossed-book checks are evaluated on the parsed payload and instruct the connector whether to
    publish, drop, or emit an additional Risk_alert. *)

type stats = {
  total_observed : int;
  sequence_gaps : int;
  dropped_to_gap : int;
  stale_ticks : int;
  crossed_books : int;
  out_of_order_trades : int;
}

type t

val create : exchange:string -> ?stale_threshold_ns:int64 -> unit -> t

(** Verdict for a single tick or trade-print observation. *)
type verdict =
  | Ok_publish
  | Drop_stale of { age_ns : int64 }
  | Drop_crossed of {
      bid : float;
      ask : float;
    }
  | Out_of_order
  | Gap_then_publish of {
      expected : int64;
      received : int64;
      dropped : int;
    }

(** {2 What [sequence] must be}

    [Some n] enables gap detection, and commits the caller to a specific guarantee: [n] is a
    per-symbol counter that increments by exactly one for each message
    {i this connector actually receives}. Anything else makes [dropped_to_gap] meaningless, and it
    will be meaningless quietly — every message will look like a gap and the counter will read in
    the millions.

    Two feeds already got this wrong. Coinbase's [sequence] field counts the product's whole full
    channel while the connector subscribes only to matches, and Binance was passing the trade
    {i timestamp in milliseconds}, so the reported "dropped" count was the elapsed time between
    trades. Both now pass the exchange's per-symbol trade id, which is dense over the messages
    received.

    [None] disables gap detection for that message. Use it when the feed offers no such counter —
    which is the case for every tick stream here, since neither exchange numbers its quote updates.
*)

(** Inspect a market-tick payload prior to publishing. *)
val check_market_tick :
  t ->
  symbol:string ->
  exchange_ts_ns:int64 ->
  ingest_ts_ns:int64 ->
  bid:float ->
  ask:float ->
  sequence:int64 option ->
  verdict

(** Inspect a trade-print payload prior to publishing. *)
val check_trade_print :
  t ->
  symbol:string ->
  exchange_ts_ns:int64 ->
  ingest_ts_ns:int64 ->
  sequence:int64 option ->
  verdict

val exchange_name : t -> string

val stats : t -> stats
