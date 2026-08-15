(** Runs live strategy instances against the event bus.

    {b Paper trading only.} See {!Algostream_runtime.Instance} — no order ever reaches a venue.

    {1 Shape}

    The same processor pattern the analytics, pairs and time-series layers use, and for the same
    reason: [Event_bus] dispatches handlers
    {i synchronously, inline, on the single dispatcher Domain}, so a slow subscriber adds latency to
    every other subscriber and eventually backs the ring up until publishes start returning [false].

    So the bus handler here does the minimum — filter, translate, enqueue — and a dedicated Domain
    drains the queue and does the real work of driving strategies. Observers read {!snapshot}, an
    immutable record published with [Atomic.set].

    {1 Control}

    {!pause}, {!resume}, {!set_allocation} and {!add} are safe to call from any Domain: they set
    atomics that the drain loop observes. They do not block on it. *)

module Event_bus = Algostream_infrastructure_event_bus.Event_bus

type t

(** [create ~bus ?queue_capacity ()] subscribes and spawns the runtime Domain. Instances are added
    with {!add}; a supervisor with none simply drains and discards. *)
val create : bus:Event_bus.t -> ?queue_capacity:int -> unit -> t

(** Register an instance. Takes effect on the next drained record.

    [false] when an instance with the same [strategy_id] is already registered, in which case
    nothing is added. {!Instance.mli} documents the id as unique but nothing used to enforce it, and
    {!find} returns the first match — so a duplicate produced a second instance that received every
    record, contributed to the aggregate, and yet could never be paused, stopped, reallocated or
    compared, because every lookup resolved to its twin. *)
val add : t -> Instance.t -> bool

val instances : t -> Instance.t list

val find : t -> strategy_id:string -> Instance.t option

(** Every instance's NAV ring, by strategy id.

    Deliberately not part of {!Snapshot.t}: the snapshot is rebuilt on every drained record, and a
    few thousand samples per instance copied at tick rate would dominate the runtime's allocation.
    Callers that want curves ask for them, at whatever cadence suits them. *)
val nav_curves : t -> (string * (int64 * float) array) list

(** Control one instance by id. [false] if no such instance. *)
val pause : t -> strategy_id:string -> bool

val resume : t -> strategy_id:string -> bool

val stop_instance : t -> strategy_id:string -> bool

val set_allocation : t -> strategy_id:string -> float -> bool

(** Total capital across instances, and the per-instance split, applied proportionally. Returns the
    allocation actually assigned to each. *)
val allocate_evenly : t -> total:float -> (string * float) list

(** Latest aggregate. Safe from any Domain. *)
val snapshot : t -> Snapshot.t

(** Stop every instance, unsubscribe, and join the runtime Domain. Safe to call twice. *)
val stop : t -> unit

val is_running : t -> bool

(** Records that arrived but could not be queued because the drain loop was behind. A non-zero value
    means the runtime is the bottleneck, not the bus. *)
val dropped_full_queue : t -> int

(** Metrics in the shape [Algostream_telemetry.Collector.provider] wants, so the daemon can register
    the runtime without either library depending on the other. *)
val telemetry_metrics : t -> unit -> (string * float) list
