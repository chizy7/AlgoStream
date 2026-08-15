(** Per-feed (per-source) health tracker.

    Wraps [Time_utils.LatencyMonitor] in a hashtable keyed by [Event.t.source] (e.g. "binance",
    "coinbase"). Tracks tick rate, last-tick-age, p99 ingest-to-handler latency, and gap counts.
    Hashtable is capped at 64 keys (LRU eviction) to bound DoS via spoofed source strings in
    third-party replay logs. *)

type t

val create : ?max_sources:int -> unit -> t

(** Record a tick observation for [source] at event-time [ts_ns]; [latency_ns] is the
    publish-to-this-call delay in nanoseconds. *)
val observe : t -> source:string -> ts_ns:int64 -> latency_ns:int64 -> unit

(** Increment the gap counter for [source]. *)
val record_gap : t -> source:string -> unit

type per_source_stats = {
  source : string;
  ticks : int64;
  gaps : int64;
  last_event_ts_ns : int64;
  avg_latency_ns : int64;
  max_latency_ns : int64;
}

val per_source : t -> source:string -> per_source_stats option

val all : t -> per_source_stats list

val active_count : t -> int
