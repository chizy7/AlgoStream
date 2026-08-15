(** Lock-free latency histogram with percentiles.

    The bus already measures latency, but {!Algostream_infrastructure_event_bus.Instrumentation}
    reports only [count], [avg], [max] and SLA violations — there are no percentiles anywhere in
    library code, and an average latency is close to useless for a system whose contract is stated
    as a tail bound. Worse, the sliding-window monitor behind it is a [Queue.t] and plain [ref]s
    written from every producer Domain at once, which is a data race.

    This replaces both concerns: a fixed array of [int Atomic.t] buckets. Recording is a bit-twiddle
    and one [Atomic.incr] — allocation-free, wait-free, and correct under concurrent producers.

    {1 Bucketing}

    Values are bucketed by exponent and mantissa, as HdrHistogram does: {!sub_bits} sub-buckets per
    power of two. Every recorded value is therefore reported to within [2 ^ -sub_bits] relative
    error — about 6% at the default of 4 — which is far finer than the run-to-run variance of the
    thing being measured.

    Percentiles are exact with respect to the bucketed data: no sampling, no reservoir, no RNG. That
    matters here, because the repo's other percentile facility
    ([Math_utils.Statistics.create_percentile_tracker]) reservoir-samples off
    [Random.State.make_self_init] and is both approximate and non-reproducible. *)

type t

(** Sub-buckets per power of two. *)
val sub_bits : int

(** [create ()] allocates a histogram covering zero up to 2^40 ns — a little over 18 minutes, far
    beyond any latency worth recording. Values at or above the ceiling land in the top bucket and
    are still counted, so the total is never wrong even if the value is clamped. *)
val create : unit -> t

(** Record one sample, in nanoseconds.

    Negative values are refused rather than folded into bucket zero, which would silently improve
    the percentiles. They are counted in {!rejected} rather than dropped without trace: a negative
    duration means either the caller subtracted timestamps in the wrong order, or measured with a
    clock that stepped backwards, and both are worth noticing. *)
val record : t -> int64 -> unit

val count : t -> int64

(** Samples refused for being negative. Non-zero means durations are being measured wrongly —
    subtracted the wrong way round, or taken from a clock that is not monotonic. A silent version of
    this counter is how exactly that bug once hid in this project. *)
val rejected : t -> int64

(** Sum of all recorded values. Combined with {!count} this gives the mean without a second pass. *)
val sum : t -> int64

(** Largest value ever recorded, exact rather than bucketed. [0L] when empty. *)
val max : t -> int64

val mean : t -> float

(** [percentile t p] for [p] in [[0, 100]]. [0L] when empty.

    Returns the upper bound of the bucket containing the [p]-th percentile — so the answer is never
    an under-estimate, and is at most [2 ^ -sub_bits] above the true value — clamped to {!max}.
    Consequently [p50 <= p90 <= p99 <= max] always holds, and [percentile t 100.0] is exactly
    {!max}.

    @raise Invalid_argument if [p] is outside [[0, 100]]. *)
val percentile : t -> float -> int64

(** Count of samples at or above [threshold] — the SLA violation count, with the threshold supplied
    at read time rather than baked in at construction. *)
val count_at_or_above : t -> int64 -> int64

(** Reset every bucket to zero. Not atomic as a whole: concurrent recorders may have samples land on
    either side of the reset. Intended for tests and for interval-based reporting where an
    approximate boundary is acceptable. *)
val reset : t -> unit

type summary = {
  count : int64;
  mean_ns : float;
  p50_ns : int64;
  p90_ns : int64;
  p99_ns : int64;
  p999_ns : int64;
  max_ns : int64;
}

val summary : t -> summary

val empty_summary : summary

val summary_to_string : summary -> string
