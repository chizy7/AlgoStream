(** Streaming tick → OHLCV bar emitter for one (symbol, interval).

    Boundary rule: [bar_open_ts = floor(tick.timestamp_ns / interval_ns) * interval_ns]. The bar
    covers [\[bar_open_ts, bar_open_ts + interval_ns)] (close-exclusive). A tick whose ts equals
    [bar_close_ts] starts the next bar.

    Late ticks (ts < current_bar.open_ts) are dropped and counted; closed bars are never rewritten.
    This guarantees real-time bar consumers see strictly monotonic, append-only bar history.

    All time arithmetic is in event time ([tick.timestamp_ns]); never reads wall-clock — replay
    determinism. *)

type t

val create : symbol:string -> interval_ns:int64 -> t

(** Update with a new observation. Returns [Some bar] when a bar boundary was just crossed (the
    previous bar is now closed); [None] otherwise. The first observed tick opens the first bar but
    does not emit. *)
val on_tick : t -> ts:int64 -> price:float -> size:float -> Bar.t option

(** Flush the current open bar at end-of-stream. Returns [Some bar] with [partial = true] if there
    is an in-progress bar; [None] if no ticks have been observed yet or the last close landed
    exactly on a boundary. Real-time stream consumers should NOT call [flush]; it's for replay-end
    finalization. *)
val flush : t -> Bar.t option

val late_tick_count : t -> int

val symbol : t -> string

val interval_ns : t -> int64
