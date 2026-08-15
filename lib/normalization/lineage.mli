(** Lightweight transformation-chain lineage encoded as a "/"-separated path string.

    Reuses the existing [Event.t.source] field — no schema change. The path documents the sequence
    of transformations a payload has been through:

    - "binance" — raw from ingestion
    - "binance/normalized" — normalized symbol applied
    - "binance/normalized/v1" — versioned downstream

    Strict format ([^[a-z0-9_]+(/[a-z0-9_]+)*$]) and 64-char cap are enforced fail-closed. *)

type t = string list

(** Split a source string on "/". Returns the empty list for an empty input. *)
val of_source : string -> t

val to_source : t -> string

(** [push parent child] appends [child] to [parent]'s path. Returns [None] if the result violates
    the format/length contract. *)
val push : string -> string -> string option

val is_valid : string -> bool

val max_length : int
