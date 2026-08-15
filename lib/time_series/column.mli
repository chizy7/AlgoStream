(** Append-only Float64 column with frozen-snapshot publication.

    A [Column.t] is a mutable, growing buffer owned by exactly one Domain. To make column data
    visible across Domains race-free, the producer calls [freeze] which allocates a fresh
    [Bigarray.Array1.t] sized to the current length. That fresh Bigarray is the *only* thing handed
    across Domain boundaries (typically inside an immutable [Snapshot.t] published via
    [Atomic.set]). The producer never mutates a frozen Bigarray afterwards.

    Cross-Domain rule: callers MUST treat any [Bigarray.Array1.t] received from [freeze] as
    immutable. Writing to it is undefined behaviour because another Domain may be concurrently
    reading. *)

type t

val create : ?capacity:int -> unit -> t

val push : t -> float -> unit

val length : t -> int

val capacity : t -> int

(** Freeze the current contents into a fresh [Float64] Bigarray of length [length t]. The returned
    array is a copy — the producer is free to continue [push]ing into [t] without affecting any
    frozen view that's already been handed out. *)
val freeze : t -> (float, Bigarray.float64_elt, Bigarray.c_layout) Bigarray.Array1.t

(** Same idea for an int64 column (for timestamps). *)
module Int64_col : sig
  type t

  val create : ?capacity:int -> unit -> t

  val push : t -> int64 -> unit

  val length : t -> int

  val freeze : t -> (int64, Bigarray.int64_elt, Bigarray.c_layout) Bigarray.Array1.t
end
