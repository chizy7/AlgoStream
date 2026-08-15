(** Canonical pair identifier.

    Legs are sorted by [Symbol.to_canonical] string order so that two callers constructing the same
    pair from opposite-ordered inputs produce equal [Pair_id.t] values. The smaller-ordered
    canonical symbol always becomes the [y] leg (the dependent variable in [y = β·x + spread]). *)

module Symbol = Algostream_normalization.Symbol

type t = private {
  y : Symbol.t;
  x : Symbol.t;
}

val of_symbols : Symbol.t -> Symbol.t -> t

val y : t -> Symbol.t

val x : t -> Symbol.t

val to_string : t -> string

val equal : t -> t -> bool

val hash : t -> int
