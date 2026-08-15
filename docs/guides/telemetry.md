# Telemetry Guide

The monitoring layer: what it measures, where each number comes from, and the one figure it cannot
honestly report during a replay.

## What the collector exposes

The collector aggregates from every subsystem without depending on any of them — subsystems
register a closure, so `algostream.telemetry` links neither ingestion, the processors nor the
runtime.

| Source | What it contributes |
|---|---|
| `Event_bus` | publish/drop counts per priority band, dispatch count, handler errors, queue depth |
| `Telemetry.Histogram` | latency percentiles — p50, p90, p99, p99.9, max — and SLA violation counts |
| `Memory_monitor.latest` | GC statistics and heap size |
| `{Analytics,Pairs,Time_series}.Processor.stats` | ticks observed, processed, dropped; active keys |
| `Ingestion.live_stats` | per-exchange drops, sequence gaps, stale ticks, crossed books |
| `Runtime.Supervisor` | instances, NAV, allocation, events processed |
| `Risk_management.Monitor` | the most recent risk snapshot, with its age |

## Percentiles, not averages

`Telemetry.Histogram` is a fixed array of `int Atomic.t` buckets, HdrHistogram-style, with
`sub_bits = 4` giving 16 sub-buckets per octave and therefore at most 6.25% relative error.
Recording is a bit-twiddle and one `Atomic.incr` — wait-free, allocation-free, and correct under
concurrent producers.

An average latency is close to useless for a system whose contract is stated as a tail bound, which
is why the percentiles live in library code rather than being computed by a benchmark binary.

> **Do not use `Time_utils.LatencyMonitor`.** It is backed by a `Queue.t` and plain `ref`s, but
> `Publish_to_enqueue` is recorded from *every producer Domain* — a data race in the hot path. It
> remains in the tree; `Telemetry.Histogram` is the supported replacement.

Percentiles are exact with respect to the bucketed data: no sampling, no reservoir, no RNG. That
matters, because the repo's other percentile facility (`Math_utils.Statistics.create_percentile_tracker`)
reservoir-samples off `Random.State.make_self_init` and is both approximate and non-reproducible.

## Measured cost

Apple Silicon, release profile, from `make tel-bench`:

| Operation | ns/op |
|---|---|
| `histogram.record` | ~13 |
| `histogram.percentile` | ~389 |
| `bus.publish` with the collector attached | ~474 |
| `collector.snapshot` | ~4 010 |

`record` is what runs inline on the dispatcher for every event, so 13 ns is the number that matters.
`snapshot` allocates and is pulled at the UI's refresh rate — 4 µs at 4 Hz is 0.0016% of a core.

## Why the collector is not a processor

The three existing bus consumers all use the same shape: an O(1) handler that enqueues into an SPSC
ring, a dedicated Domain that drains it, and an `Atomic.set` snapshot. That shape exists because
those layers do real per-tick work.

The collector does not. Its handler records one latency sample and returns. Adding a queue and a
Domain would cost more than the work it defers. Snapshot assembly, which does allocate, is **pulled**
by the caller instead of pushed.

## Decoupling

`algostream.telemetry` depends on nothing but the event bus. Subsystems register as closures:

```ocaml
Telemetry.Collector.register collector
  { Telemetry.Collector.name = "ingestion";
    metrics = (fun () -> [ ("bus_drops", 3.0); ("stale_ticks", 1.0) ]);
    health  = Some (fun () -> Health.Degraded "one feed quiet") }
```

Metrics are name/value pairs rather than a closed record, following the precedent
`Performance.Metrics.to_assoc` set. A provider that raises is reported as `Failed` and contained —
the dashboard is what you look at when something is already broken, so it must not break with it.

## Alerts

Nothing in the repo had an alert sink before this. `Risk_alert` exists as a bus payload and is
published by five sites in `data_ingestion`, but its only consumer was a `printf` in `bin/ingest.ml`.

The problem an alert system actually has to solve is repetition: a degraded feed re-evaluates every
sample period, and an alert that fires four times a second is noise. A code is therefore raised at
most once per window, with repeats folded into a count.

The window is measured **from the start of the current burst**, not from the last raise. Comparing
against the last raise would mean a condition re-evaluated faster than the window never re-notifies
at all: each raise pushes the deadline out, so a permanently broken feed would alert once and then
go quiet forever.

## Health

`GET /api/health` is the aggregate, and it answers **503** when anything reports `Failed`. It is what
the Kubernetes liveness, readiness and startup probes gate on, what the container `HEALTHCHECK`
curls, and what the `AlgoStreamUnhealthy` Prometheus rule watches — so it has to be able to fail.

Each subsystem registers a closure; the worst status wins.

| Subsystem | Degraded | Failed |
|---|---|---|
| ingestion | connecting, or reconnecting, or a feed silent for 30 s | circuit breaker open, feed silent for 120 s, or any `critical_drops` |
| runtime | strategy Domain has dropped events | ≥ 10,000 dropped |
| analytics · pairs | drain loop has dropped ticks | ≥ 10,000 dropped |

**A connected-but-silent feed is the case worth understanding.** The counters cannot detect it: a
feed producing nothing has also dropped nothing, so every quality metric reads zero and looks
perfect. Only the connection mirror's `time_since_last_message_ns` distinguishes a quiet feed from a
dead one, which is why ingestion's check reads it rather than the counters.

A check that raises is reported as `Failed` rather than propagating — one broken probe must not take
down the endpoint.

## Latency during replay

End-to-end latency is `now - event.timestamp_ns`. For a live feed that is exactly the delivery
latency. For a **replayed** log it is not: the events carry the timestamps they had when they were
recorded, so the histogram measures the age of the log — hours or days — and the SLA alert fires on
every event.

The daemon publishes `"source": "replay" | "live"` for exactly this reason, and the dashboard shows
`n/a` for SLA breaches rather than a red 100%. Treat latency as meaningful only when the source is
live.

## Source map

| Module | Path |
|---|---|
| Lock-free histogram | `lib/telemetry/histogram.{ml,mli}` |
| Health checks | `lib/telemetry/health.{ml,mli}` |
| Alert registry | `lib/telemetry/alert.{ml,mli}` |
| Bus subscription, providers, snapshot | `lib/telemetry/collector.{ml,mli}` |
| Published aggregate | `lib/telemetry/snapshot.{ml,mli}` |
| Bus flow counters | `lib/infrastructure/event_bus/event_bus.{ml,mli}` |
| Bench | `test/performance/telemetry_throughput.ml` |

## Scope and limitations

Latency, throughput, alerting, correlation status and health checks are all live.

The 50,000 ev/s throughput target and the 5 ms latency target are tracked here, but **whether they
hold against a live venue is unmeasured** — this project has no venue connectivity, so there is no
order leg to include. The figures below are publish-to-handler only, and that is the whole of what
they claim.
