(** OHLCV bar.

    Boundary semantics: the interval is half-open — inclusive of [open_ts], exclusive of [close_ts],
    where [close_ts = open_ts + interval_ns]. A tick whose timestamp equals [close_ts] belongs to
    the {i next} bar.

    [partial = true] flags a bar emitted by [BarBuilder.flush] at the end of a stream — its
    [close_ts] has not actually been crossed by a later tick. Real-time bar streams never emit
    partial bars; only [flush] does. *)

type t = {
  symbol : string;
  open_ts : int64;
  close_ts : int64;
  open_ : float;
  high : float;
  low : float;
  close : float;
  volume : float;
  n_ticks : int;
  partial : bool;
}

val to_csv_row : t -> string
