(** Per-peer backoff on failed authentication.

    Two jobs, and the second is the one that motivated it. The obvious one is slowing a brute-force
    attempt. The other is protecting the audit log: every rejected request would otherwise append a
    record and [fsync] it, so an attacker hammering the port turns a tamper-evident log into a
    disk-filling amplifier. With a limiter in front, a burst of failures produces {i one} audit
    record for the window instead of one per attempt.

    A success clears the peer's counter, so an operator who mistypes a key a few times and then
    pastes the right one is not left waiting. *)

type t

val create : unit -> t

(** Failures tolerated inside {!window_ns} before requests are refused. *)
val max_failures : int

val window_ns : int64

(** [check t ~now_ns ~peer] is [None] when the request may proceed, or [Some retry_after_s] when the
    peer is over budget — the value goes straight into a [Retry-After] header. *)
val check : t -> now_ns:int64 -> peer:string -> int option

(** Record a rejected authentication. Returns [true] when this is the failure that {i crosses} the
    threshold, which is the caller's cue to write the single audit record for the window and not
    write another until the peer recovers. *)
val note_failure : t -> now_ns:int64 -> peer:string -> bool

(** Clear a peer's history after a successful authentication. *)
val note_success : t -> peer:string -> unit

val tracked_peers : t -> int
