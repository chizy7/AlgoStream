(** Memory usage sampler for the event bus.

    Periodically polls [Gc.quick_stat] from a background thread and exposes the most recent reading.
    Cheap; intended to run continuously alongside a long-lived event bus.

    For deeper allocation tracing, set the [MEMTRACE] environment variable to a writable path before
    launching; {!init_memtrace} will start [memtrace] tracing on first call (no-op if the env var is
    unset). *)

type sample = {
  timestamp_ns : int64;
  minor_words : float;
  promoted_words : float;
  major_words : float;
  heap_words : int;
  live_words : int;
  free_words : int;
  stack_size : int;
}

type t

(** Allocate a monitor; does not start sampling. *)
val create : unit -> t

(** Spawn a sampler thread that polls every [interval_ms] ms (default 1000). *)
val start : ?interval_ms:int -> t -> unit

(** Signal the sampler thread to exit. Safe to call twice. *)
val stop : t -> unit

(** Most recent sample, or [None] if the sampler hasn't taken one yet. *)
val latest : t -> sample option

val pp_sample : sample -> string

(** One-shot init: if [MEMTRACE] is set in the environment, call [Memtrace.start_tracing] writing a
    CTF trace to that path (sampling rate 1e-4). Otherwise no-op. Safe to call from anywhere;
    idempotent. *)
val init_memtrace : unit -> unit
