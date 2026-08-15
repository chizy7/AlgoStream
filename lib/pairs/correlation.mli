(** Thin wrapper around [Rolling_corr]: per-pair price-level Pearson correlation. *)

type t

val create : window:int -> recompute_every:int -> t

val update : t -> y:float -> x:float -> float

val value : t -> float

val n : t -> int
