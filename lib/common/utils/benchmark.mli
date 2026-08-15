(** Benchmarking and optimization utilities for ultra-low latency trading *)

(** Benchmark result type *)
type benchmark_result = {
  name : string;
  iterations : int;
  total_time_ns : int64;
  avg_time_ns : int64;
  min_time_ns : int64;
  max_time_ns : int64;
  median_time_ns : int64;
  p95_time_ns : int64;
  p99_time_ns : int64;
  std_dev_ns : float;
  throughput_ops_per_sec : float;
}
[@@deriving sexp]

(** Benchmark configuration *)
type benchmark_config = {
  warmup_iterations : int;
  measurement_iterations : int;
  target_latency_ns : int64;
  cpu_affinity : int option;
  gc_settings : [ `Default | `Low_latency | `High_throughput ];
  memory_prefault : bool;
}
[@@deriving sexp]

val default_config : benchmark_config

(** CPU affinity and performance optimization.

    A thin convenience layer over {!Affinity}, which is where the platform story is documented. *)
module CPUOptimization : sig
  (** Pin the calling thread to [core]. Really pins on Linux; [Error] everywhere else. *)
  val isolate_cpu : int -> (unit, string) result

  (** Always [Error]. The CPU governor and turbo boost are root-level sysfs settings that a process
      cannot apply to itself; the operator does this at the machine level. Kept rather than deleted
      so the answer is discoverable at the call site instead of only in a guide. *)
  val optimize_for_latency : unit -> (unit, string) result

  (** [Some c] where [c] is the last core, when the machine has more than four. [None] otherwise —
      on a small machine there is no core to spare. *)
  val get_recommended_cpu : unit -> int option
end

(** Memory optimization utilities *)
module MemoryOptimization : sig
  val optimize_gc_for_latency : unit -> unit

  val optimize_gc_for_throughput : unit -> unit

  val prefault_heap : unit -> unit
end

(** High-precision benchmark runner *)
module BenchmarkRunner : sig
  val run_benchmark : name:string -> config:benchmark_config -> f:(unit -> unit) -> benchmark_result
end

(** Critical path benchmarks for trading system *)
module TradingBenchmarks : sig
  val benchmark_ring_buffer : unit -> unit -> unit

  val benchmark_lock_free_stack : unit -> unit -> unit

  val benchmark_order_book_update : unit -> unit -> unit

  val benchmark_timestamp_generation : unit -> unit -> unit

  val benchmark_timer_operations : unit -> unit -> unit

  val benchmark_mmap_read : unit -> unit -> unit

  val benchmark_zero_copy_send : unit -> unit -> unit

  val benchmark_zero_copy_receive : unit -> unit -> unit

  val run_all_benchmarks : ?config:benchmark_config -> unit -> benchmark_result list
end

(** Performance analysis and reporting *)
module PerformanceAnalysis : sig
  val format_time_ns : int64 -> string

  val format_throughput : float -> string

  val print_benchmark_result : benchmark_result -> unit

  val generate_performance_report : benchmark_result list -> unit

  val export_to_csv : benchmark_result list -> string -> unit

  (** Emit results as JSON in the [customSmallerIsBetter] schema consumed by
      [benchmark-action/github-action-benchmark]. Each entry is
      {[
        {"name": <name>, "unit": "ns", "value": <avg_time_ns>,
         "extra": "p95=<p95>ns p99=<p99>ns iter=<n>"}
      ]} *)
  val export_to_json : benchmark_result list -> string -> unit
end

(** Continuous performance monitoring *)
module PerformanceMonitor : sig
  type monitor

  val create : benchmarks:(string * (unit -> unit)) list -> config:benchmark_config -> monitor

  val run_monitoring_cycle : monitor -> benchmark_result list

  val start_continuous_monitoring : monitor -> interval_seconds:int -> unit

  val stop_monitoring : monitor -> unit

  val get_last_results : monitor -> benchmark_result list
end
