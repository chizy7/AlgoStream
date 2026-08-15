(** Latency instrumentation for the event bus.

    Reuses [Time_utils.LatencyMonitor] for sliding-window stats and SLA violation tracking; adds
    three named hookpoints:

    - [publish_to_enqueue] : producer call → ring-buffer push completed
    - [enqueue_to_dispatch] : event sat in ring buffer → dispatcher popped it
    - [dispatch_to_handler] : per-subscriber handler runtime

    All recording goes through {!record}; producers compute the duration themselves from
    [Clock.now_monotonic_ns] timestamps to keep the hot path free of monad allocations. *)

type t

(** [create ?window_size ?sla_ns ()] sets up per-phase monitors with the given sliding-window length
    (default 4096) and SLA violation threshold (default 5_000_000 ns = 5ms). *)
val create : ?window_size:int -> ?sla_ns:int64 -> unit -> t

type phase =
  | Publish_to_enqueue
  | Enqueue_to_dispatch
  | Dispatch_to_handler
  | End_to_end

val phase_to_string : phase -> string

(** Record a duration sample for [phase]. Cheap; no-op when instrumentation is disabled. *)
val record : t -> phase -> int64 -> unit

(** Toggle the instrumentation gate at runtime. *)
val set_enabled : t -> bool -> unit

val is_enabled : t -> bool

type phase_stats = {
  count : int;
  avg_ns : int64;
  max_ns : int64;
  violations : int;
}

type stats = {
  publish_to_enqueue : phase_stats;
  enqueue_to_dispatch : phase_stats;
  dispatch_to_handler : phase_stats;
  end_to_end : phase_stats;
}

val snapshot : t -> stats

val pp_stats : stats -> string
