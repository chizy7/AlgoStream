(** Corporate actions / data discontinuities.

    Generalizes splits, dividends, symbol changes, forks, and trading halts into a single variant.
    v1 only populates [Symbol_change] and [Halt] from JSON config (sufficient for crypto). [Split] /
    [Dividend] / [Fork] are wired and ready for equities + future crypto forks. *)

type t =
  | Split of { ratio : float } (* equity: post = pre * ratio (e.g. 2-for-1 split: ratio = 2.0) *)
  | Dividend of {
      amount : float;
      currency : string;
    }
  | Symbol_change of {
      from_ : string;
      to_ : string;
    }
  | Fork of {
      parent : string;
      children : (string * float) list; (* (symbol, ratio) *)
    }
  | Halt of { until_ns : int64 }

type entry = {
  effective_at_ns : int64;
  break_ : t;
  source : string;
}

(** Simplified Tick value for [apply] — narrower than the full Tick.tick to keep the data_break
    layer testable in isolation. *)
type tick = {
  symbol : string;
  ts_ns : int64;
  price : float;
  size : float;
}

type verdict =
  | Pass
  | Rewrite of tick
  | Drop
  | Emit_synthetic of tick list

(** Apply the relevant (effective-at <= tick.ts) entries to a tick. The list is expected to be
    sorted by [effective_at_ns]. *)
val apply : entry list -> tick -> verdict

val load_file : string -> (entry list, string) result
