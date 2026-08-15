# Dashboard Guide

The monitoring UI and the HTTP API behind it. Run it with `make dash`.

## What's in the box

| Piece | Path |
|---|---|
| HTTP API + Server-Sent Events | `lib/infrastructure/network/` |
| Outbound JSON encoders | `lib/infrastructure/network/json.{ml,mli}` |
| Charting, hand-rolled inline SVG | `site/assets/chart.js` |
| The page | `site/dashboard/` |
| Daemon that wires it together | `bin/algostream.ml` |

> **Security, up front.** The API exposes strategy start/stop/pause and allocation, so it is
> authenticated: bearer API keys with `read` and `control` scopes, and every control action written
> to a hash-chained audit log. Pass `--auth-keys` to enable it. Without a keystore the daemon serves
> unauthenticated and will **refuse to bind a non-loopback address** rather than expose an open
> control surface. See the [security guide](security.md).

## Server-Sent Events, not WebSocket

Updates are pushed over Server-Sent Events rather than a WebSocket, deliberately.

The dashboard needs one thing: the server pushing state to the browser several times a second. That
is what SSE is — a long-lived `text/event-stream` response. It needs no upgrade handshake, no frame
masking, no SHA-1, no ping/pong keepalive, and no second protocol implementation to get wrong; and
`EventSource` reconnects on its own, which a WebSocket client must be taught to do.

A WebSocket would earn its complexity only if the browser had to send a continuous stream back, and
it does not — control actions are a handful of POSTs.

The client falls back to polling `/api/telemetry` + `/api/strategies` if `EventSource` is missing or
the stream fails repeatedly, because some proxies buffer `text/event-stream` into uselessness.

## Where to see it

| | |
|---|---|
| **Live** | `make dash` → `http://127.0.0.1:8080/dashboard/`. Needs a running daemon. |
| **Demo** | [`/dashboard/`](../dashboard/) on the published site — a recorded snapshot, nothing updates. |

A live dashboard renders state from a running process, and GitHub Pages serves static files, so the
published copy cannot be live. On load the page probes `/api/health` once: if a daemon answers it
opens the SSE stream, and if nothing answers it renders `demo.json` — a frame captured from a real
replay run — behind a banner saying so. One probe rather than waiting for retries to fail, because
on Pages `/api` and `/events` are plain 404s and the page would otherwise sit blank for seconds.

The controls are present in demo mode and do nothing; there is no daemon to receive the POST.

## Endpoints

| Method | Path | Notes |
|---|---|---|
| `GET` | `/api/health` | `503` when overall status is `failed`; **readiness**, not liveness |
| `GET` | `/api/live` | always `200` while the server can answer; **liveness** only |
| `GET` | `/api/telemetry` | latency percentiles, bus flow, components, alerts |
| `GET` | `/api/strategies` | every instance; carries `"mode": "paper"` |
| `GET` | `/api/strategies/:id` | one instance |
| `GET` | `/api/compare?a=&b=` | two instances side by side; `409` until they overlap enough |
| `POST` | `/api/strategies/:id/{pause,resume,stop}` | `404` for an unknown id |
| `PUT` | `/api/strategies/:id/allocation` | body is a bare number; `400` otherwise |
| `GET` | `/api/reports` | available report names |
| `GET` | `/api/reports/:name?format=csv\|json` | see the reporting guide |
| `GET` | `/events?ticket=…` | SSE stream, 4 Hz by default; needs a single-use ticket when auth is on |
| `POST` | `/api/stream-ticket` | mints a 30-second single-use ticket for `/events` |
| `GET` | `/api/whoami` | the presenting key's id and scopes |
| `GET` | `/metrics` | Prometheus exposition format; `read` scope |

## Strategy comparison

`GET /api/compare?a=ID&b=ID` reports two running instances against each other: standalone metrics
for each, plus `b_vs_a` — alpha, beta, correlation, tracking error, information ratio and capture
ratios, with **A as the benchmark**. The dashboard renders it as a panel that appears only when two
instances are running.

Start a second instance with `--variant`:

```bash
dune exec bin/algostream.exe -- --variant max_gross_pct_of_nav=0.15 --static site/
```

That registers `pairs-2` on the same market as `pairs-1` with those parameter overrides. Both see
the same records from the same supervisor, so the comparison measures the parameters and nothing
else.

**Why it is a separate endpoint rather than a field on the SSE frame.** The frame goes out at 4 Hz
to every connected client; two NAV curves of a few thousand points each would be tens of kilobytes
per second per client, for rings that only advance once a second. The dashboard polls this on its
own five-second timer instead.

**The join is the interesting part.** Two live instances sample on their own timers, so their
curves cannot be compared positionally the way `Benchmark_compare` assumes — it truncates to the
shorter series, which is right for a backtest and wrong here. `Nav_align` restricts to the window
both curves cover, takes the sorted union of their timestamps, and carries the last observation
forward. Forward-carry rather than interpolation: a NAV between two samples is the earlier one,
because that is what the portfolio was actually worth, and interpolating would leak information
backwards from a sample that had not happened yet.

Refusals are distinguishable and deliberate: `404` for an unknown id, `400` when either parameter is
missing, and `409` for the two "not yet" cases — no overlapping window, or fewer than eight aligned
points, below which beta and correlation are noise.

## Non-finite floats

Yojson emits bare `NaN` and `Infinity`, which are not JSON and which every browser's `JSON.parse`
rejects outright. Financial metrics produce both routinely — a Sharpe ratio over zero variance, a
leverage ratio on an empty portfolio. `Json.float` maps them to `null` so one degenerate metric
cannot make an entire response unparseable.

## Encoding stays in the network layer

`lib/performance` and `lib/risk_management` are pure and dependency-light. Teaching them to
serialize would be new dependency surface on the two libraries least suited to it, so they expose
`to_assoc`-style accessors instead and `network/json` does the encoding. Every variant in the tree
already has a `_to_string`, which makes each one a one-line encoder.

## No D3.js

The original design called for "interactive charting with D3.js integration". `site/assets/chart.js` is
hand-rolled inline SVG instead. The site is strictly zero-external-request, the benchmark dashboard
already draws its sparklines this way, and vendoring ~280 KB of third-party JavaScript into a
repository that hand-rolls its own RNG and numerics would be out of character for the sake of axes
that take twenty lines to compute. Recorded as a deliberate substitution, in the same spirit as the
genetic-algorithm deferral.

## Rendering discipline

`innerHTML` is only ever assigned a **static literal** skeleton. Every value that came from the
daemon goes in through `textContent`, and every class through `classList`. A symbol or strategy tag
containing markup therefore cannot become markup.

## Panels

System health and latency, throughput, per-band queue depth, subsystem status, the portfolio NAV
curve, strategy control, positions, recent fills, and active alerts.

The simulated-execution banner sits above all of them and is the most important element on the page.

## Known gaps / follow-ups

- **No correlation heatmap.** `Analytics.Processor.correlation` is a documented stub returning
  `0.0`; the panel is omitted rather than rendering a grid of zeros. `Pairs.Snapshot.corr` is real
  and does appear per pair.
- **No order-book depth visualisation.** The runtime does not retain book snapshots.
- **NAV history is in-browser only.** The chart holds a bounded ring of what arrived since the page
  opened; reloading starts it over. Durable series would need a store the daemon does not have.
- **One report shape.** `/api/reports/:name` returns CSV inside a JSON string field rather than as a
  file download, so every response has the same shape.

## Source map

| Module | Path |
|---|---|
| Route matching, SSE hub, static files | `lib/infrastructure/network/server.{ml,mli}` |
| JSON encoders | `lib/infrastructure/network/json.{ml,mli}` |
| Charting | `site/assets/chart.js` |
| Page and client | `site/dashboard/` |
| Tests | `test/network/` |

