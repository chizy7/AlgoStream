# System Overview

What AlgoStream is made of and how the pieces fit together.

**Scope.** This is research infrastructure with simulated execution. There is no venue connectivity
in the project today: no exchange credentials, no request signing, no trading endpoint. Fills are
simulated against live quotes.

## Shape

```
exchange feeds ──► ingestion ──► event bus ──┬──► time series ──┐
                                             ├──► analytics ────┤
                                             ├──► pairs ────────┤
                                             │                  ▼
                                             │              strategy
                                             │                  │
                                             │                  ▼
                                             └──► runtime ──► fill simulation ──► portfolio
                                                       │
                                                       ▼
                                                   telemetry ──► HTTP API ──► dashboard
                                                                     │            SSE
                                                                     └──► /metrics (Prometheus)
```

The **event bus is first**, not a downstream integration point. Everything that observes market data
subscribes to it, and everything that produces market data publishes into it. The bus is the
system's only shared mutable structure.

## Concurrency model

OCaml 5 `Domain`s, with one convention applied everywhere:

> A bus handler does O(1) work and enqueues. The real work happens on the subscriber's own Domain,
> which publishes an immutable snapshot via `Atomic.set`. Readers on other Domains `Atomic.get` it.

This matters because **the bus dispatches handlers synchronously, inline, on a single dispatcher
Domain**. A handler that does real work adds latency to every other subscriber. The pattern is not
stylistic — it is the reason the system stays responsive with several processors attached.

| Domain | Owns |
|---|---|
| Bus dispatcher | Drains the four priority bands and invokes handlers |
| Time series | Bar construction, alignment, compression |
| Analytics | Rolling statistics per symbol |
| Pairs | Hedge ratio, spread, z-score, cointegration per pair |
| Runtime | Strategy state, fill simulation, portfolio |
| Lwt host | The process's single `Lwt_main.run` — ingestion fibers and the HTTP server |

There is exactly one `Lwt_main.run` in the process, in `lib/infrastructure/lwt_host/`. CI asserts
it appears in exactly one file, because `Lwt_engine` is process-global state and a second scheduler
would be a silent correctness problem.

## Layers

**Ingestion** (`lib/data_ingestion/`) — WebSocket connectors for Binance and Coinbase with a
circuit breaker, reconnect backoff, rate limiting and per-feed health tracking. Public market data
only. Outbound TLS verifies against system trust anchors.

**Normalization and time series** (`lib/normalization/`, `lib/time_series/`) — canonical symbols
across venues, bar construction on an event-time grid, cross-feed alignment, compression.

**Analytics and pairs** (`lib/analytics/`, `lib/pairs/`) — rolling mean, variance and correlation;
hedge ratio by rolling OLS or Kalman, spread z-score, Engle-Granger cointegration with MacKinnon
critical values, AR(1) half-life. Johansen is an explicit stub rather than a plausible-looking
implementation.

**Advanced models** (`lib/advanced_models/`) — Ornstein-Uhlenbeck, Kalman filtering, GARCH, regime
detection. Hand-rolled rather than pulled from a linear-algebra dependency.

**Strategy and backtest** (`lib/strategy/`, `lib/backtest/`) — `Strategy.S` is a pure decision
function returning `Action.t list` rather than submitting orders, so risk gating and routing stay
outside it. `lib/strategy` depends on neither the event bus nor the backtester, and a test asserts
that. The fill simulator models queue position, time-in-force, stops, icebergs, venue fees, slippage
and a latency delay queue.

**Order and risk management** (`lib/order_management/`, `lib/risk_management/`) — routing across
venue snapshots, position sizing, execution-quality analysis; VaR by several methods, exposure
limits, circuit breakers, pre-trade checks.

**Research** (`lib/montecarlo/`, `lib/optimization/`, `lib/performance/`) — bootstrap and regime
simulation, walk-forward analysis, purged k-fold and CPCV, deflated Sharpe and PBO, attribution and
drawdown analysis. The RNG is a reproducible xoshiro implementation in `lib/rng/`; CI enforces its
use and bans `Random.self_init` in these layers, because a backtest that cannot be reproduced is not
a measurement.

**Runtime** (`lib/runtime/`) — drives a `Strategy.S` against the live bus using the same fill
engine and cost model as the backtester. `test/runtime/test_parity.ml` asserts the two produce
identical fills, counters and NAV from one fixture. That equivalence is the strongest claim
available without a venue.

**Telemetry** (`lib/telemetry/`) — a lock-free HdrHistogram-style latency histogram, health checks
with staleness budgets, an alert registry with burst-window dedup, and a collector that reaches
subsystems through registered closures rather than by depending on them.

**Interface** (`lib/infrastructure/network/`) — HTTP API, Server-Sent Events at 4 Hz, static file
serving, and a Prometheus `/metrics` endpoint.

## Security

The control surface can start, pause, stop and reallocate strategies, so it is authenticated.

- **Bearer API keys** with two scopes, `read` and `control`. Keys are 256 bits from the OS CSPRNG,
  stored only as a SHA-256 digest. Every route declares the scope it requires as a mandatory field,
  so a new endpoint cannot forget to.
- **Bearer header only** — no cookie session. That is deliberate: requiring `Authorization` forces a
  CORS preflight the server never answers, which defeats a cross-site control request with no CSRF
  machinery. A cookie would reintroduce exactly that attack.
- **Hash-chained audit log** (`lib/infrastructure/persistence/`) records every control action with
  principal attribution. The chain is unkeyed, so its guarantee is that any change moves the head
  hash — which is why an out-of-band anchor is required rather than optional.
- **A non-loopback bind with no keystore is refused**, exiting non-zero rather than warning.
- **Inbound TLS is a documented deferral**; terminate it at a reverse proxy.

This is two scopes over hashed bearer keys — not RBAC, and there is no MFA. The full threat model,
including what is explicitly out of scope, is in the [security guide](../guides/security.md).

## Technology

| Concern | Choice |
|---|---|
| Language | OCaml 5.x — `Domain` for parallelism, `Atomic` for publication |
| Async I/O | Lwt, with a single scheduler for the whole process |
| HTTP | cohttp + conduit; SSE rather than WebSocket for push |
| Serialisation | `bin_prot` for the event log, Yojson for the API and config |
| Crypto | `digestif` (SHA-256), `mirage-crypto-rng` for key generation |
| Persistence | Append-only binary event log; no database |
| Numerics | Hand-rolled — no Owl, Lacaml or GSL |
| Deployment | Docker; Kubernetes manifests are schema-validated only |

There is no database. The event log is an append-only `bin_prot` file with CRC32 framing that reads
back independently, which is what makes deterministic replay possible.

## Operational properties

- **Determinism.** Pure layers may not read the clock; CI greps for it. Event time comes from the
  event, so a replay reproduces a live run exactly.
- **Backpressure.** Ring buffers are bounded and drop rather than block, with per-band counters. A
  drop is visible in telemetry rather than manifesting as unbounded latency.
- **Observability.** 56 Prometheus series, nine alert rules derived from the same conditions the
  in-process alert registry evaluates, so the two cannot disagree.
- **Failure isolation.** Handler exceptions are caught and counted rather than killing the
  dispatcher; a dead SSE client is reaped rather than stalling the broadcast.

## Known limits

- No venue connectivity, so uptime against an exchange, real execution latency and any P&L figure
  are unmeasurable. Where a target cannot be validated without a venue, the guides say so rather
  than reporting a number.
- Not horizontally scalable as written — each instance opens its own feeds and runs its own
  strategy copy, so a second replica means duplicate subscriptions, not shared load.
- Kubernetes manifests and the blue/green script are schema-validated and shellcheck-clean but have
  never been applied to a cluster.
