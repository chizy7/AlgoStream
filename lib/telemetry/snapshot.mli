(** The immutable aggregate a monitoring client reads.

    Built on demand by {!Algostream_telemetry.Collector.snapshot}. Every field is a plain value, so
    the record can be handed across Domains and serialized without further coordination. *)

type latency = {
  end_to_end : Histogram.summary;
    (** Publish to delivery, measured by the collector's own bus subscription. This is where the
        p50/p99/p99.9 figures come from — the bus's own [Instrumentation] tracks only count, avg,
        max and violations. *)
  sla_ns : int64;
  sla_violations : int64;  (** samples at or above [sla_ns] *)
  sla_violation_pct : float;
}

type bus = {
  depth : int;
  depth_per_band : int array;
    (** indexed by [Priority.to_int]; a band near capacity is about to start dropping *)
  subscriber_count : int;
  published : int64;
  dropped : int64;
  dropped_per_band : int64 array;
  dispatched : int64;
  handler_errors : int64;
  events_per_sec : float;  (** derived between consecutive snapshots; [0.0] for the first *)
}

(** A subsystem that registered itself with the collector. Metrics are name/value pairs rather than
    a closed record so that [algostream.telemetry] need not depend on ingestion, the processors or
    the runtime — it is handed closures instead. This follows the precedent set by
    [Performance.Metrics.to_assoc]. *)
type component = {
  name : string;
  metrics : (string * float) list;
  status : Health.status;
}

type t = {
  ts_ns : int64;  (** monotonic, matching event timestamps *)
  wall_ns : int64;  (** realtime, for display *)
  uptime_ns : int64;
  latency : latency;
  bus : bus;
  components : component list;
  health : Health.report list;
  overall : Health.status;
  alerts : Alert.t list;
}

(** Flat name/value view of the numeric fields, for a generic metrics table or a quick export.
    Component metrics are prefixed with the component name. *)
val to_assoc : t -> (string * float) list

val to_string : t -> string
