(** Prometheus text exposition format.

    A pure rendering of {!Snapshot.to_assoc} — no registry, no global state, no client library. The
    snapshot is already a flat [(string * float) list] with component names prefixed, which is
    almost exactly what the exposition format wants; what remains is name sanitisation, [# HELP] and
    [# TYPE] lines, and knowing which metrics are counters.

    {1 Why not a Prometheus client library}

    The wire format is thirty lines of string building and is specified in a page of prose. A client
    library would bring a registry with its own mutable global state into a process that has been
    careful about exactly that, to solve a problem that does not exist here: this exporter has one
    caller, serving one snapshot that is already assembled.

    {1 Naming}

    Prometheus metric names match [[a-zA-Z_:][a-zA-Z0-9_:]*], so dots become underscores and
    anything else illegal is dropped. Every name is prefixed [algostream_]. Names that collide after
    sanitisation would silently merge into one series, so {!render} disambiguates rather than
    emitting duplicates — a metrics endpoint that quietly loses a series is worse than an ugly name.

    {1 Counters versus gauges}

    Getting this wrong makes [rate()] meaningless, so the classification is explicit rather than
    guessed from the value. Anything cumulative and monotonic — published, dropped, dispatched,
    errors, violations — is a counter; everything else is a gauge. *)

(** [render snapshot] is a complete exposition-format document, ending in a newline. *)
val render : Snapshot.t -> string

(** The content type Prometheus expects. Serving [application/json] here makes a scrape fail with a
    parse error rather than a helpful message. *)
val content_type : string

(** Exposed for testing: the sanitised, prefixed metric name for a snapshot key. *)
val metric_name : string -> string
