# Getting Started

Building AlgoStream, running the tests, and getting a live dashboard in front of you.

**Execution is simulated.** There is no venue connectivity in this project today: no credentials,
no request signing, no trading endpoint. Every fill is simulated against live quotes. Nothing in
this guide, or anywhere else, will place a real order.

## Prerequisites

- **OCaml 5.1.x** recommended; 5.0.x is supported and both are in the CI matrix. The project uses
  `Domain` throughout, so 4.x will not build it.
- **opam** for package management.
- **Docker** — optional, needed only for `perf`/`valgrind` profiling on macOS and for the
  observability stack.

## Installation

```bash
git clone https://github.com/chizy7/AlgoStream.git
cd AlgoStream
```

The fastest path uses the bundled setup script, which creates a local switch in `_opam/` and
installs everything including the dev tools:

```bash
./scripts/setup-dev.sh
eval $(opam env)
```

The manual equivalent:

```bash
opam switch create . ocaml-base-compiler.5.1.1
eval $(opam env)
opam install . --deps-only --with-test --with-dev-setup
```

> If `make` fails with `Library ... not found`, the shell is almost certainly on a 4.x switch.
> `eval $(opam env)` from the project root fixes it.

## Build and test

```bash
make build           # dune build
make test            # dune runtest — 709 alcotest cases
make fmt             # dune build @fmt --auto-promote
make fmt-check       # CI-style check; fails rather than fixing
```

A fresh build takes well under a minute; the test suite runs in a few seconds.

## Run it

The quickest look at a working system:

```bash
make dash
```

Then open **http://127.0.0.1:8080/dashboard/** — note the path, since `/` is the landing page. The
daemon connects to public exchange feeds, runs a pairs strategy against them, and pushes state to
the browser over SSE at 4 Hz.

Without a keystore the API serves unauthenticated and binds loopback only. To turn authentication
on:

```bash
algostream-keyctl add --label laptop --scopes read,control    # printed once; only its hash is stored

dune exec bin/algostream.exe -- \
  --auth-keys ~/.config/algostream/keys.json \
  --audit-dir /tmp/algostream-audit \
  --static site/ --http-port 8080
```

The dashboard then prompts for the key. A `read`-scoped key streams live but leaves the control
buttons disabled; a `control` key enables them. See the [security guide](security.md).

`dune exec bin/algostream.exe -- --help` lists every flag.

## Run a backtest

Generate a deterministic fixture and replay it through the engine:

```bash
make fixture OUT=/tmp/fixture.log BARS=5000
dune exec bin/backtest.exe -- --log /tmp/fixture.log --y BTCUSDT --x ETHUSDT
```

The engine reports fills, NAV and the usual performance statistics. The same `Strategy.S` runs
unchanged against the live runtime — `test/runtime/test_parity.exe` asserts the two produce
identical results from one fixture, which is what makes a backtest here worth anything.

See [backtesting](backtesting.md) and [writing a strategy](strategy_development.md).

## Benchmarks

```bash
make bench           # core performance suite
make bench-json      # same, writing bench_results.json in the CI schema
make paced-bench     # event-bus latency at a stated offered load
```

`paced-bench` is the number to quote for latency: it offers a fixed rate (50,000 ev/s by default)
and reports the distribution under that load. The other latency benchmark saturates the bus on
purpose and therefore reports queueing delay in the tens of milliseconds — both are real, but they
answer different questions. [Operations](operations.md) explains the distinction.

## Profiling

`perf`, `valgrind` and `gprof` are Linux-only, so on macOS they live in the dev container:

```bash
make docker-dev      # builds Dockerfile.dev and brings the container up
make docker-shell    # bash into it
```

Inside:

```bash
make perf-record                                          # writes perf.data
make valgrind-massif                                      # heap profile
make memtrace BIN=bin/event_replay.exe ARGS="--log-file replay.bin"
```

The dev container grants passwordless sudo and runs with `seccomp:unconfined` so the profilers
work. That is correct for development and disqualifying for anything else — the production image is
a separate `Dockerfile`. See [deployment](deployment.md).

## Where to go next

| If you want to | Read |
|---|---|
| Write a strategy | [Writing a strategy](strategy_development.md) |
| Understand the event bus | [Event bus](event_bus.md) |
| Know what the domain types guarantee | [Domain models](domain_models.md) |
| Run it somewhere other than your laptop | [Deployment](deployment.md) |
| Turn on authentication and the audit trail | [Security](security.md) |
| Diagnose something that has gone wrong | [Operations runbook](operations.md) |

## Troubleshooting

**`Library "..." not found`** — the active switch is not the project's. Run `eval $(opam env)` from
the project root.

**Build failures after pulling** — `dune clean && dune build`. If the tree contains files named
`foo 2.ml`, they are sync-conflict copies and will break the build; delete them.

**The dashboard shows "recorded snapshot"** — the page probed `/api/health`, nothing answered, and
it fell back to the bundled demo fixture. Either the daemon is not running or the port differs.

**Latency looks terrible** — check the source first:
`curl -s localhost:8080/api/telemetry | jq .source`. On a replay, latency is measured as
`now - event.timestamp`, so it reports the age of the log rather than a delivery time.

**Everything returns 401** — the daemon has a keystore and the request has no usable credential.
`curl -s localhost:8080/api/health | jq .auth_required` confirms whether authentication is on.

**`--replay` raises `event_log: header truncated`** — it needs a real event log, not an empty file
or `/dev/null`. Make one with `make fixture OUT=/tmp/f.log BARS=5000`.

**`--pin-cores` does nothing on macOS**, and says so. Pinning is `sched_setaffinity`, which is
Linux-only; macOS's `THREAD_AFFINITY_POLICY` is an advisory hint that Apple Silicon ignores, so the
call reports `Unsupported` rather than a success it did not achieve.
