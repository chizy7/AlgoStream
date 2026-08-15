(** Per-Domain string interning for symbols.

    Avoids repeated allocation of identical symbol strings on the parser hot path. NOT thread-safe;
    each ingestion Domain owns its own table. *)

type t

val create : ?initial_size:int -> unit -> t

(** Return the canonical interned copy of [s]. First call for a given value allocates; subsequent
    calls return the cached string. *)
val intern : t -> string -> string

(** Intern a substring of [b] without first allocating an unbound copy. The implementation still
    allocates exactly once on first sighting. *)
val intern_bytes : t -> Bytes.t -> off:int -> len:int -> string

val size : t -> int
