# Event Bus Guide

`algostream.infrastructure.event_bus` is the event-driven
infrastructure layer. It provides a multi-band priority queue, a
predicate-based filter/subscription system, an append-only binary log
with replay, and four named latency hookpoints that surface
publish-to-handler statistics in real time.

This guide covers everything you need to publish, subscribe, persist,
replay, and instrument events.

---

## 1. Concepts

| Concept             | Module            | Purpose                                                                                                                           |
| ------------------- | ----------------- | --------------------------------------------------------------------------------------------------------------------------------- |
| `Event.t`           | `Event_types`     | Immutable record carrying a `payload`, `priority`, `timestamp_ns`, `sequence_id`, and `source` string. Derives `bin_io` + `sexp`. |
| `Priority`          | `Event_types`     | `Critical / High / Normal / Low` (4 bands; lower index = higher priority).                                                        |
| `Filter.t`          | `Subscription`    | Predicate combinators evaluated once per dispatch.                                                                                |
| `Event_bus.t`       | `Event_bus`       | Facade owning the priority queue + dispatcher `Domain`.                                                                           |
| `Event_log`         | `Event_log`       | Append-only binary log with CRC32-protected frames.                                                                               |
| `Instrumentation.t` | `Instrumentation` | 4 latency hookpoints over `Time_utils.LatencyMonitor`.                                                                            |
| `Memory_monitor.t`  | `Memory_monitor`  | `Gc.quick_stat` sampler + `memtrace` init.                                                                                        |

The bus is single-process. Per-subscriber async queues are a planned
follow-up; today, handlers run synchronously inside the dispatcher
domain — keep them short.

---

## 2. Quick start

```ocaml
open Algostream_infrastructure_event_bus

let () =
  let bus = Event_bus.create () in

  let _id =
    Event_bus.subscribe bus (fun e ->
      Printf.printf "got seq=%Ld pri=%s\n"
        e.sequence_id
        (Event_types.Priority.to_string e.priority))
  in

  Event_bus.start bus;

  for _ = 1 to 1000 do
    Event_bus.publish bus
      (Event_types.Event.create
         ~priority:Event_types.Priority.High
         Event_types.Event.Heartbeat)
  done;

  (* let the dispatcher drain *)
  Algostream_common_utils.Time_utils.Sleep.sleep_ms 50L;

  Event_bus.stop bus;
  print_endline (Instrumentation.pp_stats (Event_bus.stats bus))
```

`Event_bus.create` defaults to `capacity_per_band:4096` and an SLA
threshold of 5 ms; both are tunable. The bus is created in the _stopped_
state — you must call `start` before the dispatcher domain runs. `stop`
is registered automatically as an `at_exit` hook on first start, so a
missed call won't leave an orphan domain.

---

## 3. Priority bands

Bands are tried in strict order: every event in `Critical` is delivered
before the dispatcher consults `High`, and so on. This keeps shutdown
and risk-alert events ahead of routine market data, but admits
theoretical starvation of `Low` under sustained `Critical` traffic.
Round-robin / token quotas are a documented follow-up.

```ocaml
Event_bus.publish bus
  (Event_types.Event.create
     ~priority:Event_types.Priority.Critical
     (Event_types.Event.Risk_alert
        { code = "VAR_BREACH"; message = "limit breached"; severity = 3 }))
```

`try_publish` returns `false` if the matching band is full;
`publish` is a fire-and-forget convenience.

---

## 4. Filtering

Filters are predicate combinators — closures evaluated once per
dispatch, no string allocations on the hot path.

```ocaml
open Subscription.Filter

(* Only AAPL ticks at High priority or above *)
let f = and_ (by_symbol "AAPL") (min_priority Event_types.Priority.High)

let _id = Event_bus.subscribe_filtered bus f handle_tick
```

Available combinators: `any`, `by_priority`, `min_priority`, `by_source`,
`by_message_type` (uses `Zero_copy.MessageType` codes),
`by_symbol`, `and_`, `or_`, `not_`, `custom`.

`by_symbol` works for `Market_tick`, `Order_request`, `Trade_execution`,
and `Strategy_signal` payloads (returns `false` for `Heartbeat`,
`Shutdown`, `Raw`, etc.).

---

## 5. Persisting and replaying events

The event log is an append-only binary file using bin_prot framing.
Header is 64 bytes, magic `0x41534454` ("ASDT"); each frame
is `[u32 length | u32 crc32 | bin_prot bytes]`.

> **Schema versions**: writer emits **v3** (added the `Trade_print`
> and `Data_gap` payload constructors). The reader accepts v2 and v3
> headers — old v2 logs continue to replay against the current code, but
> v3 logs cannot be opened by binaries built before log format v3 (the new payload tags
> would deserialize as garbage). Constructor _additions_ go at the end
> of the variant; renaming or reordering still requires another version
> bump.

### Writing

```ocaml
let writer = Event_log.Writer.create "session.log" in
Event_log.Writer.append writer event;
(* ... *)
Event_log.Writer.close writer  (* rewrites the header with final counts *)
```

### Reading

```ocaml
let reader = Event_log.Reader.open_ "session.log" in
let n = Event_log.Reader.iter reader (fun e -> handle e) in
Event_log.Reader.close reader;
Printf.printf "read %d events\n" n
```

`iter` stops cleanly on EOF or the first bad CRC — partial-write
recovery is built in.

### Replaying into a fresh bus

```ocaml
let n =
  Event_log.replay bus
    ~path:"session.log"
    ~speed:10.0       (* 10x real-time; default Float.infinity = ASAP *)
    ~filter:(Subscription.Filter.by_symbol "AAPL")
    ()
```

The CLI wrapper:

```sh
make replay LOG=session.log SPEED=1.0
# or directly:
dune exec bin/event_replay.exe -- --log-file session.log --speed 1.0 --print
```

---

## 6. Latency instrumentation

Every event records four phase-bracketed measurements:

| Phase                 | What it measures                            |
| --------------------- | ------------------------------------------- |
| `Publish_to_enqueue`  | producer call → ring-buffer push completed  |
| `Enqueue_to_dispatch` | event sat in queue → dispatcher popped it   |
| `Dispatch_to_handler` | per-subscriber handler runtime              |
| `End_to_end`          | producer publish → last subscriber returned |

Each phase has its own `LatencyMonitor` (sliding window 4096, SLA
threshold 5 ms by default). Snapshot:

```ocaml
let s = Event_bus.stats bus in
Printf.printf "max end-to-end = %Ldns (avg %Ldns, SLA violations: %d)\n"
  s.end_to_end.max_ns s.end_to_end.avg_ns s.end_to_end.violations
```

`phase_stats` carries `count`, `avg_ns`, `max_ns` and `violations` — **there are no percentiles
here**. The `p50/p95/p99` figures on the benchmark dashboard are computed by the bench itself
(`test/performance/event_bus_latency.ml`) from a raw sample array. For live percentiles use
`Algostream_telemetry.Histogram`, which the collector feeds from the same hookpoints.

To disable instrumentation in a hot path (e.g. production):

```ocaml
Instrumentation.set_enabled (Event_bus.instrumentation bus) false
```

The hot-path cost when enabled is 4 × `Clock.now_monotonic_ns ()` per
event (~80 ns total on modern hardware).

---

## 7. Memory profiling

Two cooperating layers, both wired through `Memory_monitor`:

### `Gc.quick_stat` sampler (always available)

```ocaml
let mm = Memory_monitor.create () in
Memory_monitor.start ~interval_ms:1000 mm;
(* ... *)
match Memory_monitor.latest mm with
| Some s -> print_endline (Memory_monitor.pp_sample s)
| None -> print_endline "no samples yet"
```

Records minor/promoted/major/heap/live/free words and stack size every
`interval_ms` (default 1000 ms). Atomic-load on `latest`; cheap.

### `memtrace` (optional, env-gated)

```sh
MEMTRACE=trace.ctf dune exec bin/event_replay.exe -- --log-file session.log
# then:
opam install memtrace_viewer
memtrace-viewer trace.ctf
```

Call `Memory_monitor.init_memtrace ()` once at process start (e.g. in
`main`); it inspects `MEMTRACE` and starts CTF tracing at sampling rate
1e-4 if set, otherwise no-op.

---

## 8. Continuous benchmarking

`bin/benchmark.exe` and the two `test/performance/` binaries all accept
`--json PATH` and emit results in the
[`customSmallerIsBetter`](https://github.com/benchmark-action/github-action-benchmark#examples)
schema:

```json
[
  {
    "name": "event_bus.publish_to_handler.p99",
    "unit": "ns",
    "value": 3436032,
    "extra": "n=50000"
  }
]
```

CI runs all three on every push to `main` and every PR
(`.github/workflows/benchmark.yml`), combines them with `jq -s 'add'`,
and posts to `benchmark-action/github-action-benchmark@v1` with
`alert-threshold: 200%`. PRs that regress more than 2× get a comment
and a job failure; main-branch results auto-push to `gh-pages` for
historical tracking.

Local equivalent:

```sh
make bench-json   # writes bench_results.json
```

---

## 9. Performance numbers (reference)

Measured on Apple Silicon dev hardware, OCaml 5.1.0, release profile:

| Metric                                 | Value             |
| -------------------------------------- | ----------------- |
| Event bus end-to-end (heartbeat) — avg | ~2.1 ms           |
| Event bus end-to-end — p99             | ~3.4 ms           |
| Event bus throughput                   | ~1.82M events/sec |
| `RingBuffer.push`/`pop` — avg          | 34 ns / 39 ns     |
| `Clock.now_monotonic_ns` — avg         | 74 ns             |

GitHub Actions runners are noisier (±20–40%). Treat CI numbers as
regression detectors, not absolute targets.

---

## 10. Known limitations

- **Synchronous handlers**: per-subscription async SPSC queues are a
  documented follow-up. Today, all handlers for a given event run
  serially in the dispatcher domain. Keep handlers under ~100 µs.
- **Strict-priority starvation**: `Low` band events can be starved
  indefinitely under sustained `Critical` traffic. A round-robin token
  scheme is planned.
- **Domain payloads**: `Trade.t` / `Order.t` / `Tick.t` are _not_ used
  directly in `Event.payload` — that would force `ppx_jane` into the
  domain layer. The payload variant uses self-contained record types
  with the same fields. Mirror-conversion helpers may be added in a
  later PR if needed.
- **mmap is a portable-mode stub**: `Event_log` uses plain stdlib
  `Unix.write`/`Unix.read` rather than mmap, because
  `lib/common/utils/portable_stubs.c` does not implement the actual
  `mmap` syscall on portable mode. Real mmap support can be added
  later without changing the on-disk format.

---

## 11. Where to look in the source

| Thing                    | File                                              |
| ------------------------ | ------------------------------------------------- |
| Event types              | `lib/infrastructure/event_bus/event_types.ml`     |
| Priority queue           | `lib/infrastructure/event_bus/priority_queue.ml`  |
| Filters / subscriptions  | `lib/infrastructure/event_bus/subscription.ml`    |
| Bus facade + dispatcher  | `lib/infrastructure/event_bus/event_bus.ml`       |
| Latency hookpoints       | `lib/infrastructure/event_bus/instrumentation.ml` |
| Append-only log + replay | `lib/infrastructure/event_bus/event_log.ml`       |
| Memory profiling         | `lib/infrastructure/event_bus/memory_monitor.ml`  |
| Replay CLI               | `bin/event_replay.ml`                             |
| Latency benchmark        | `test/performance/event_bus_latency.ml`           |
| Throughput benchmark     | `test/performance/event_bus_throughput.ml`        |
| Tests                    | `test/infrastructure/event_bus/`                  |
