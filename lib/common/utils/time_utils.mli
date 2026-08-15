(** High-resolution timing utilities for ultra-low latency trading *)

(** Time representation in nanoseconds since Unix epoch *)
type timestamp_ns = int64

(** Duration in nanoseconds *)
type duration_ns = int64

(** Clocks.

    Both are [clock_gettime] via C stubs. The distinction matters and is not stylistic:
    {!now_monotonic_ns} never decreases and is the only one safe to subtract, while
    {!now_realtime_ns} tracks the wall clock and can step backwards.

    {b There is no cycle counter here, deliberately.} Reading a TSC is architecture-specific and
    needs a calibration this project does not perform, so rather than offer an interface that
    implies the capability, there is none. Use {!now_monotonic_ns}. *)
module Clock : sig
  (** Monotonic nanoseconds. Never decreases, so differences are always non-negative.

      The epoch is unspecified — the absolute value means nothing and only differences are defined.
      This is the clock to measure any duration with. *)
  val now_monotonic_ns : unit -> int64

  (** Wall-clock nanoseconds since the Unix epoch.

      {b Steps.} NTP correction, a manual clock change or a VM resume can move it backwards, so
      subtracting two readings can yield a negative duration. Use it for timestamps a human or an
      audit record will read, never to measure elapsed time. *)
  val now_realtime_ns : unit -> int64
end

(** Timestamp creation and manipulation *)
module Timestamp : sig
  val now : unit -> timestamp_ns

  val now_monotonic : unit -> timestamp_ns

  val of_unix_time_s : float -> timestamp_ns

  val to_unix_time_s : timestamp_ns -> float

  val of_unix_time_ms : int64 -> timestamp_ns

  val to_unix_time_ms : timestamp_ns -> int64

  val of_unix_time_us : int64 -> timestamp_ns

  val to_unix_time_us : timestamp_ns -> int64

  val add_duration : timestamp_ns -> duration_ns -> timestamp_ns

  val sub_duration : timestamp_ns -> duration_ns -> timestamp_ns

  val diff : timestamp_ns -> timestamp_ns -> duration_ns

  val compare : timestamp_ns -> timestamp_ns -> int

  val to_string : timestamp_ns -> string
end

(** Duration utilities *)
module Duration : sig
  val nanosecond : duration_ns

  val microsecond : duration_ns

  val millisecond : duration_ns

  val second : duration_ns

  val of_ns : int64 -> duration_ns

  val of_us : int64 -> duration_ns

  val of_ms : int64 -> duration_ns

  val of_s : int64 -> duration_ns

  val to_ns : duration_ns -> int64

  val to_us : duration_ns -> int64

  val to_ms : duration_ns -> int64

  val to_s : duration_ns -> int64

  val to_float_s : duration_ns -> float

  val to_float_ms : duration_ns -> float

  val to_float_us : duration_ns -> float

  val add : duration_ns -> duration_ns -> duration_ns

  val sub : duration_ns -> duration_ns -> duration_ns

  val mul : duration_ns -> int -> duration_ns

  val div : duration_ns -> int -> duration_ns

  val compare : duration_ns -> duration_ns -> int

  val to_string : duration_ns -> string
end

(** High-precision timer for performance measurement *)
module Timer : sig
  type t

  val create : unit -> t

  val start : unit -> t

  val lap : t -> duration_ns

  val elapsed : t -> duration_ns

  val reset : t -> unit

  val average_lap_time : t -> duration_ns
end

(** Statistics type for latency analysis *)
type latency_stats = {
  count : int;
  total : duration_ns;
  avg : duration_ns;
  min_duration : duration_ns;
  max_duration : duration_ns;
  median : duration_ns;
  p95 : duration_ns;
  p99 : duration_ns;
}

(** Latency measurement utilities *)
module Latency : sig
  type measurement = {
    start_ns : timestamp_ns;
    end_ns : timestamp_ns;
    duration_ns : duration_ns;
    label : string;
  }

  type tracker

  val create_tracker : unit -> tracker

  val start_measurement : tracker -> string -> unit

  val end_measurement : tracker -> measurement option

  val get_measurements : tracker -> measurement list

  val clear_measurements : tracker -> unit

  val measure_function : string -> (unit -> 'a) -> 'a * measurement

  val get_statistics : measurement list -> latency_stats option
end

(** Real-time latency monitoring *)
module LatencyMonitor : sig
  type t

  val create : window_size:int -> violation_threshold_ns:duration_ns -> t

  val add_measurement : t -> duration_ns -> unit

  val get_current_avg : t -> duration_ns

  val get_max_latency : t -> duration_ns

  val get_violation_count : t -> int

  val reset : t -> unit
end

(** Sleep with high precision *)
module Sleep : sig
  val sleep_ns : duration_ns -> unit

  val sleep_us : int64 -> unit

  val sleep_ms : int64 -> unit

  val busy_wait_ns : duration_ns -> unit

  val busy_wait_us : int64 -> unit
end
