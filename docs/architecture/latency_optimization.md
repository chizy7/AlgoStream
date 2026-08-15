# Latency

What AlgoStream measures, how it measures it, and which numbers mean what.

Every figure here comes from a benchmark in `test/performance/` or from `bench_results.json`, and
each says which machine produced it. Nothing below is a claim about performance in general.

## The measurement that matters, and the one that misleads

The project's stated target is a sub-5 ms event path. There are two latency benchmarks and they
report numbers two orders of magnitude apart. Both are correct; they measure different things, and
confusing them is the single easiest way to draw a wrong conclusion here.

| Benchmark | What it does | Apple Silicon, release |
|---|---|---|
| `event_bus_paced_latency` | Offers a **fixed rate** (50,000 ev/s) and measures publish-to-handler | **p50 0.07 ms · p99 0.15 ms** |
| `order_path_latency` | The whole decision path for one order, as a distribution | **p50 1.0 µs · p99 3.8 µs** |
| `event_bus_latency` | Publishes as fast as the producer can, unpaced | p50 17.1 ms · p99 18.0 ms |

The second is not a slower version of the first. It saturates the bus deliberately: a tight
producer loop outruns the single dispatcher Domain, the ring backs up, and what it reports is
**queueing delay at 100% offered load** — the time an event waits behind a backlog, not the time the
system takes to handle it. That is a useful thing to track, because it describes how the system
degrades under overload. It is not comparable to a latency target.

Its metrics are named `event_bus.saturated_queueing.*` for that reason.

**Quote the paced number.** `make paced-bench RATE=50000`.

### Coordinated omission

A paced benchmark that measures from when it *managed* to publish rather than from when it
*intended* to will hide exactly the stalls it exists to find: if the system pauses, a naive
publisher pauses with it, publishes late, and records a short latency for an event that was
badly delayed.

`event_bus_paced_latency` stamps each event with its **scheduled** time rather than the actual one,
so any time the publisher itself spent behind schedule lands in the measurement. It also reports
`behind_avg` and warns when the publisher could not sustain the requested rate — a run where the
machine could not offer the load is visible rather than silently folded into the latency figures.

## The decision path

`order_path_latency` times the sequence a single order actually travels:

```
tick observed → strategy decides → risk gate → position sizing → routing → fill admitted
```

**p50 1.0 µs, p99 3.8 µs** over 200,000 iterations after a 20,000-iteration warmup — three orders of
magnitude under the 5 ms target.

Two things about that figure are worth stating plainly, and the benchmark prints both rather than
leaving them to be discovered:

- **p99.9 is 0.22 ms and the maximum is 19 ms.** Those are GC pauses, not path cost. The path is
  the p50/p99 figures; the far tail is the major collector, which is stop-the-world across every
  Domain. Reporting the maximum as order-path latency would blame the wrong component, and omitting
  it would be worse.
- **The venue leg does not exist.** AlgoStream is paper trading — no exchange connectivity, no order
  placement, no acknowledgement. This answers the latency target only for the part the project
  controls. Real execution latency is dominated by the network round trip and the venue's matching
  engine, neither of which is measurable here.

```bash
dune exec test/performance/order_path_latency.exe -- --iters 200000
```

## Component costs

From `bench_results.json` (Apple Silicon, release profile):

| Operation | Cost |
|---|---|
| Monotonic clock read | 45 ns |
| Realtime clock read | 43 ns |
| Ring buffer push | 69 ns |
| Ring buffer pop | 61 ns |
| Timestamp generation (critical path) | 48 ns |
| Math operations (critical path) | 27 ns |
| Ring buffer operations (critical path) | 1120 ns |

The last row is a composite of many operations, not a single push; it is listed because a reader
comparing it against the 69 ns figure would otherwise assume one of them is wrong.

> **A clock read is comparable to a ring-buffer operation, so instrumentation is not free.** The bus
> takes four clock reads per event plus two per matching subscriber; at ~45 ns each that is a real
> fraction of the per-event cost. `Instrumentation.set_enabled false` gates the recording, though
> the clock reads still happen.
>
> **The clock series has a discontinuity.** It was `Unix.gettimeofday` at ~144 ns until it moved to
> `clock_gettime`, which made it both correct — the wall clock steps, so durations could come out
> negative — and about three times cheaper, since it resolves through the vDSO rather than OCaml's
> `Unix` stub. Readings either side of that change are not comparable.

## Where the time goes

The hot path is:

```
publish → priority queue enqueue → dispatcher dequeue → handler invocation
```

- **Enqueue** is a lock-free ring-buffer write into one of four priority bands. Allocation-free.
- **Dispatch** runs on a single `Domain.spawn`ed loop that drains bands in priority order.
- **Handlers run inline, synchronously, on that dispatcher Domain.** This is the most important
  performance property in the system: a slow handler adds latency to *every other subscriber*. It is
  why every processor uses the same pattern — an O(1) bus handler that enqueues into an SPSC queue,
  with the real work happening on the processor's own Domain.

Subscribers that need to do work therefore never do it in the handler. See
[data flow](data_flow.md).

## GC, and what OCaml 5 actually honours

`--gc-tune` sets a 16 MiB minor heap and `space_overhead 80`. That is the whole tuning, and the
reason it is so short is worth knowing.

**OCaml 5 silently ignores several `Gc.control` fields that still exist in the record.** Measured on
the 5.0 switch: requesting `major_heap_increment` and `max_overhead` leaves both reading back `0` —
the OCaml 5 major collector is incremental mark-and-sweep with no compaction, so neither knob
exists. `allocation_policy` is likewise inert. Setting them does nothing except suggest a tuning
that is not happening.

Two further traps:

- **`minor_heap_size` is in words, not bytes.** `2 * 1024 * 1024` is 2M words — **16 MiB** on
  64-bit, not 2 MB.
- **Do not set `stack_limit` while tuning GC.** It has nothing to do with collection latency, and
  lowering it is a stack-overflow risk for anything deeply recursive.

Why the minor heap is the lever that matters: **OCaml 5 minor collections are stop-the-world across
every Domain.** Each one pauses the bus dispatcher, all three processors and the runtime at once.
Fewer, larger minor collections is the whole game.

## CPU pinning

`--pin-cores` assigns cores to Domains in spawn order — dispatcher, the processor drain loops, the
runtime, the Lwt host. Each Domain pins itself from inside its own entry point, which is what
`sched_setaffinity` with a pid of `0` does on Linux.

**Linux only.** macOS exposes `THREAD_AFFINITY_POLICY`, but it is an advisory hint that groups
threads into affinity sets rather than binding one to a core, and Apple Silicon ignores it. Rather
than report a success it did not achieve, `Affinity.pin` returns `` `Unsupported `` there.

Both flags default off. Pinning on a machine you do not own — shared, oversubscribed, or with fewer
cores than the process has Domains — trades the scheduler's global view for a fixed guess, and
usually loses.

NUMA binding is not in-process; OCaml's GC offers no hook to bind heap pages to a node. Use a
launcher:

```bash
numactl --cpunodebind=0 --membind=0 algostream --pin-cores 2,3,4,5
```

## What is not optimised, and why

- **No flambda.** The project does not set `-O3 -unbox-closures -inline 100`. Those require a
  flambda switch; on a stock compiler `-O3` is silently accepted and does nothing, which is worse
  than an error because it looks like it worked. The hot paths are already allocation-free ring
  buffer operations, and the gain has not been demonstrated.
- **Almost no C.** Three stubs are compiled — `portable_stubs.c`, `affinity_stubs.c` and
  `clock_stubs.c` — and `lib/common/utils/` contains several more `.c` files that are not. Only the
  clock and CPU pinning have a C path; the maths is plain OCaml.
- **No kernel bypass.** DPDK and AF_XDP are out of scope. Socket options are also out of reach:
  `Websocket_lwt_unix.connect` returns an abstract connection and performs its own connect, so the
  file descriptor never surfaces — and `TCP_NODELAY` would buy little on a subscribe-once-then-read
  market data feed.

## Reproducing

```bash
make paced-bench RATE=50000 SECONDS=4   # the latency figure
make bench-json                          # component costs, CI schema
```

CI tracks every metric run-to-run via `benchmark-action/github-action-benchmark`, published at
[dev/bench](https://chizy7.github.io/AlgoStream/dev/bench/). The alert threshold is deliberately
loose: measured on identical commits, some metrics vary by more than 15x between runs on shared CI
hardware, so a tight threshold produces nothing but false regressions.

See also [performance tuning](../guides/performance_tuning.md) for the operator-level settings and
[operations](../guides/operations.md) for interpreting these numbers in a running system.
