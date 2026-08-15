(** Gathers everything a monitoring client needs into one {!Snapshot.t}.

    {1 Why this is not a processor}

    The three existing bus consumers ([Analytics], [Pairs], [Time_series]) all use the same shape:
    an O(1) handler that enqueues into an SPSC ring, a dedicated Domain that drains it, and an
    [Atomic.set] snapshot. That shape exists because those layers do real per-tick work — filters,
    regressions, bar building — which must not run on the dispatcher.

    The collector does not. Its handler records one latency sample into a lock-free histogram and
    bumps a counter: two atomic operations, no allocation, no branching on payload. Adding a queue
    and a Domain would cost more than the work it defers. Snapshot assembly, which does allocate, is
    pulled by the caller instead of pushed.

    {1 Decoupling}

    Subsystems are registered as {!provider} closures rather than being linked directly, so this
    library depends on nothing but the event bus. The daemon wires ingestion, the processors and the
    runtime in at start-up. *)

type t

(** A subsystem that reports metrics. [metrics] is polled each time a snapshot is built and must be
    cheap and non-blocking — read an [Atomic.t], do not compute. [health], when present, is polled
    at the same time. *)
type provider = {
  name : string;
  metrics : unit -> (string * float) list;
  health : (unit -> Health.status) option;
}

(** [create ~bus ?sla_ns ?alert_window_ns ()]. [sla_ns] defaults to 5 ms, matching the bus and the
    project's stated latency target. *)
val create :
  bus:Algostream_infrastructure_event_bus.Event_bus.t ->
  ?sla_ns:int64 ->
  ?alert_window_ns:int64 ->
  unit ->
  t

(** Register a provider. May be called before or after {!start}; providers are read only when a
    snapshot is built. *)
val register : t -> provider -> unit

(** Register a health check evaluated on every snapshot. *)
val add_check : t -> Health.check -> unit

(** Subscribe to the bus and begin sampling. Idempotent. *)
val start : t -> unit

(** Unsubscribe. Snapshots still work afterwards; the histogram simply stops growing. *)
val stop : t -> unit

val is_running : t -> bool

(** Build a snapshot. Allocates; intended to be called at the UI's refresh rate, not per event.

    Safe from any Domain. The derived [events_per_sec] is computed against the previous call, so
    calling from several places at once makes that one field noisier — everything else is exact. *)
val snapshot : t -> Snapshot.t

(** The alert registry, so a notifier can read it directly or a rule engine can raise into it. The
    collector raises its own alerts for SLA breaches, drop rate and handler errors on each
    {!snapshot}. *)
val alerts : t -> Alert.registry

(** {1 Replay and latency}

    End-to-end latency is measured as [now - event.timestamp_ns]. For a live feed that is exactly
    the delivery latency. For a {b replayed} log it is not: the events carry the timestamps they had
    when they were recorded, so the histogram measures the age of the log — hours or days — and the
    SLA alert fires on every event. Treat latency as meaningful only when the source is live. *)

(** Stop raising [LATENCY_SLA] without stopping measurement.

    Latency is [now - event.timestamp_ns], which is a delivery time only when the source is live. On
    a replayed log the events carry the timestamps they were recorded with, so every event trips the
    SLA and the alert is a false positive on every one of them. Samples are still recorded — the
    distribution is still worth seeing — but the rule stays quiet. Default [true]. *)
val set_latency_alerting : t -> bool -> unit

val latency_alerting : t -> bool

(** Latency histogram, exposed for benchmarks and tests. *)
val latency_histogram : t -> Histogram.t

(** Discard accumulated latency samples and counters. Does not touch alerts or providers. *)
val reset : t -> unit
