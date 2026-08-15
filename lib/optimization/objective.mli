(** What the optimizer maximizes.

    Always maximized: a minimizing objective is expressed by negating [f]. That keeps every
    comparison in the library a single [>] with no direction flag to get backwards. *)

module Metrics = Algostream_performance.Metrics

type t = {
  name : string;
  f : Metrics.t -> float;  (** higher is better *)
}

val sharpe : t

val sortino : t

val calmar : t

val ann_return : t

val total_return : t

(** [-max_drawdown] — for a mandate where capital preservation dominates. *)
val min_drawdown : t

(** Annual return divided by maximum drawdown. Closely related to Calmar but uses arithmetic rather
    than geometric return, so it is less sensitive to a short sample. *)
val return_over_max_dd : t

(** [base − lambda · max_drawdown]. The workhorse: a raw Sharpe objective happily selects a
    configuration that made its money in one lucky stretch and spent the rest underwater. *)
val penalized : base:t -> lambda:float -> t

(** Wrap any objective so it scores zero unless the result has at least [min_trades] trades and
    [min_periods] observations. Without this, a configuration that traded twice and got lucky
    outranks one that traded five hundred times and worked. *)
val require_activity : base:t -> min_trades:int -> min_periods:int -> n_trades:(unit -> int) -> t

val custom : name:string -> f:(Metrics.t -> float) -> t

(** Score, mapping a non-finite result to [neg_infinity] so a degenerate configuration can never
    win. *)
val score : t -> Metrics.t -> float
