(** Real-time volatility estimators.

    [Realized] computes the annualization-naive realized volatility — sqrt of the rolling sum of
    squared log-returns — over a fixed window. Caller can scale to any time unit by multiplying.

    [Ewma] is a streaming EWMA over squared log-returns, with bias correction inherited from
    [Filters.Ewma_var]. Both estimators ignore the very first sample (no return defined). *)

(* ───── Realized volatility (rolling window of log-returns) ──────── *)

module Realized : sig
  type t

  val create : window:int -> recompute_every:int -> t

  (** Returns the realized volatility (std dev of log-returns) over the most recent [window] ticks.
  *)
  val update : t -> price:float -> float

  val value : t -> float

  val n : t -> int
end

(* ───── EWMA volatility ──────────────────────────────────────────── *)

module Ewma : sig
  type t

  val create : period:int -> t

  val update : t -> price:float -> float

  val value : t -> float

  val ready : t -> bool
end
