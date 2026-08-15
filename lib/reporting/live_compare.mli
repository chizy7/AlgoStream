(** Compare two running strategy instances.

    The last open item in strategy management. Everything it needs already existed and was reachable
    from nothing: {!Algostream_runtime.Instance.nav_curve} had no callers,
    {!Algostream_performance.Metrics.of_nav} takes exactly its type,
    {!Algostream_performance.Benchmark_compare.compare} is a ready-made A-versus-B vector, and
    {!Algostream_infrastructure_network.Json.of_series} serialises the curve. What was missing was
    the join: two live instances sample on their own timers, so their curves cannot be compared
    positionally. {!Algostream_performance.Nav_align} supplies the grid; this module puts the pieces
    together.

    Both arms are computed on the {i aligned} grid, so the metrics reported for A here can differ
    slightly from A's own standalone metrics — a comparison is only meaningful over the window both
    curves cover, and that window is usually shorter than either curve. *)

module Metrics = Algostream_performance.Metrics
module Benchmark_compare = Algostream_performance.Benchmark_compare

type t = {
  a_id : string;
  b_id : string;
  n_periods : int;  (** points on the aligned grid; [0] when the curves do not overlap *)
  overlap_ns : int64;
  periods_per_year : float;  (** inferred from the grid's median spacing *)
  a_metrics : Metrics.t;
  b_metrics : Metrics.t;
  relative : Benchmark_compare.t;  (** B measured against A: A is the benchmark *)
  a_curve : (int64 * float) array;  (** on the aligned grid, for charting *)
  b_curve : (int64 * float) array;
}

type error =
  [ `Unknown_instance of string
  | `Same_instance of string
  | `No_overlap
  | `Too_short of int
  ]

val error_to_string : error -> string

(** Minimum aligned points before a comparison is reported at all. Below this, beta, correlation and
    tracking error are dominated by noise and quoting them would be worse than declining. *)
val min_periods : int

(** Compare the two named instances of a supervisor. [b] is measured against [a]. *)
val of_supervisor :
  Algostream_runtime.Supervisor.t -> a_id:string -> b_id:string -> (t, error) Stdlib.result

(** Compare two curves directly. Exposed for testing and for offline use. *)
val of_curves :
  a_id:string ->
  b_id:string ->
  a:(int64 * float) array ->
  b:(int64 * float) array ->
  (t, error) Stdlib.result

val to_json : t -> Yojson.Safe.t
