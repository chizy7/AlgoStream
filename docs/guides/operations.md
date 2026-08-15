# Operations Runbook

What to do when something is wrong. Each section names a symptom you would actually see, what it
usually means, and how to tell the usual cause from the misleading one — because most of these have
a second explanation that looks identical from the outside.

Paper trading throughout. Nothing here can lose money; it can lose data and observability.

## Every alert has a look-alike

Start here. The most common way to waste an hour is to diagnose the obvious cause.

| Alert | Obvious cause | The look-alike that costs you the hour |
|---|---|---|
| `AlgoStreamDown` | The daemon is down | **The scrape key was revoked.** A 401 on every scrape looks identical to an unreachable target |
| `AlgoStreamLatencySLABreach` | The system is slow | **You are pointed at a replay.** Latency is `now - event.timestamp`, so a recorded log reports its own age |
| `AlgoStreamFeedStalled` | The feed died | The daemon is running with `--no-strategy`, or `--replay` finished |
| `AlgoStreamEventsDropped` | Overload | **One slow subscriber.** Handlers run inline on the dispatcher Domain, so one of them backs up all of them |
| `AlgoStreamUnhealthy` | The system is broken | **A feed is unreachable from where you are deployed.** Health is worst-wins, so one geo-blocked exchange fails the whole endpoint |

## The daemon will not start

### `refusing to bind the dashboard API to … with no keystore`

Working as intended. A non-loopback bind with no credential exposes strategy start/stop to the
network, so it exits 2 rather than warning.

```bash
algostream-keyctl add --label operator --scopes read,control
algostream --auth-keys ~/.config/algostream/keys.json --http-host 0.0.0.0 …
```

If TLS is terminated by a proxy in front, add `--insecure-plaintext-bind`. If it is not, fix that
first — bearer tokens would cross the network in the clear.

### `… is mode 0644 — it must not be readable by group or others`

```bash
chmod 600 ~/.config/algostream/keys.json
```

Refused rather than warned, deliberately: a detached daemon's warnings go unread.

### `keystore version N, expected 1` / `duplicate key id`

The file was hand-edited. `algostream-keyctl list` reads it the same way the daemon does, so use
that to check a repair before restarting.

## Authentication problems

### Everything returns 401

```bash
curl -s localhost:8080/api/health | jq .auth_required
```

`/api/health` is always public — the dashboard uses it to tell a live daemon from the recorded demo.
If `auth_required` is `true`, the daemon has a keystore and your request has no usable credential.

```bash
curl -i -H "Authorization: Bearer $KEY" localhost:8080/api/telemetry
```

Read the `WWW-Authenticate` header; it distinguishes the cases.

### 403, not 401

The credential is fine and the scope is not. 403 is deliberate: retrying with that key will never
work.

```bash
algostream-keyctl list                              # check the scopes column
algostream-keyctl add --label ops --scopes read,control
```

### 429 with `Retry-After`

Five failed attempts within a minute. It exists to protect the audit log as much as to slow a brute
force: without it every rejected request would append and `fsync` a record, turning a tamper-evident
log into a disk-filling amplifier. A single successful authentication clears the counter.

### A revoked key still works

Wait one second. The daemon re-`stat`s the keystore at most once a second. If it persists past that,
the reload is failing — check the logs for `keystore reload failed`, which means the daemon is
deliberately still serving the last good copy rather than locking you out over a hand-edit.

## The dashboard is blank or shows stale data

### It says "recorded snapshot"

The page probed `/api/health` and nothing answered, so it rendered the bundled demo fixture. Either
the daemon is not running, the port differs, or you are looking at the GitHub Pages copy, which has
no daemon by design.

### The page loads but never updates

The event stream is not open. It needs a ticket:

```bash
TICKET=$(curl -s -XPOST -H "Authorization: Bearer $KEY" localhost:8080/api/stream-ticket | jq -r .ticket)
curl -N "localhost:8080/events?ticket=$TICKET"
```

Tickets are **single use** and last 30 seconds. A client that reconnects must mint a fresh one; a
reused ticket is a 401, which is correct and is also the most likely cause of a stream that opened
once and never came back.

Behind a reverse proxy, check `proxy_buffering off`. A buffering proxy delivers nothing until its
buffer fills, which for a 4 Hz stream is indistinguishable from a hang.

### Latency shows red, everything else looks fine

Check the source first:

```bash
curl -s localhost:8080/api/telemetry | jq .source
```

`"replay"` means the numbers are the age of the log, not delivery times. The daemon disables
in-process latency alerting when replaying and the dashboard greys those cells — but Prometheus
rules cannot tell, so a scrape against a replay will page you.

## Health reports degraded or failed

`/api/health` answers **503** when any subsystem reports `Failed`, and that is what the Kubernetes
probes, the container `HEALTHCHECK` and the `AlgoStreamUnhealthy` rule all gate on. The reason
string names the subsystem:

```bash
curl -s localhost:8080/api/health | jq .status
curl -s -H "Authorization: Bearer $KEY" localhost:8080/api/telemetry | jq '.components[] | {name, status}'
```

| Reason | What it means |
|---|---|
| `<feed> circuit breaker is open` | Repeated connection failures tripped the breaker. Check reachability first — a geo-blocked or firewalled exchange looks exactly like an outage |
| `<feed> feed: silent for …` | The socket is up and nothing is arriving. The most misleading state, because every quality counter reads zero |
| `<feed> reconnecting (attempt N)` | Transient if N stays low; a climbing N means the endpoint is refusing |
| `<feed> dropped N critical events` | Data gaps or circuit-breaker events were lost. Treat as an incident — this is the signal the counter exists to protect |
| `<subsystem> queue: N dropped` | A drain loop is behind. Check whether one subscriber is slow: handlers run inline on the dispatcher Domain, so one slow handler backs up all of them |

A component whose check raises is reported `Failed` with the exception text, so a broken probe shows
up as itself rather than taking the endpoint down.

**Health is aggregate and worst-wins.** One failed feed fails the whole endpoint, which for a
two-feed setup means a single geo-blocked exchange takes the pod out of the Service. That is
deliberate — a strategy trading a pair across two venues with one venue dark is not healthy — but it
is worth knowing before pointing a readiness probe at it in a multi-region deployment.

## Events are being dropped

```bash
curl -s -H "Authorization: Bearer $KEY" localhost:8080/metrics | grep dropped
```

A band's ring buffer filled and `try_publish` failed. Handlers run **synchronously, inline, on the
single dispatcher Domain**, so one slow subscriber adds latency to every other subscriber and backs
up the ring behind all of them. Check per-processor `dropped_full_queue` counters to find which
drain loop is behind before assuming the machine is simply overloaded.

`*_critical_drops` is the one to treat as an incident: the critical band carries data gaps and
circuit-breaker events, so dropping them loses exactly the signal the counter exists to protect.

## Verifying the audit trail

```bash
algostream-auditctl verify /var/lib/algostream/audit   # exit 1 on a break — cron-friendly
algostream-auditctl tail   /var/lib/algostream/audit --lines 50
algostream-auditctl head   /var/lib/algostream/audit
```

`auditctl` deliberately does not link the daemon or any of its libraries. A verifier that shares
code with the writer can share a bug with it.

### `verify` reports a break

Do not restart into the same directory and do not run a backup without `--force`; `backup.sh`
refuses a broken chain precisely so an archive does not preserve the tampering instead of the
evidence.

1. `algostream-auditctl tail` — records before the break are still readable and still verified.
2. Compare `head` against your out-of-band anchor. If the anchor matches an earlier state, you know
   when it diverged.
3. Preserve the file before touching anything else.

### `verify` passes but you still do not trust it

Correct instinct. The chain is unkeyed, so anyone who can write the file can recompute every hash
and produce a log that verifies perfectly. Tail truncation leaves no trace at all.

**Only the anchor closes this.** Compare the current head against the value you recorded somewhere
the daemon cannot write. `scripts/restore.sh` does this automatically when an anchor is present, and
a cleanly truncated log demonstrates the point: it reports "chain intact" and the anchor still
catches it.

If you have never recorded an anchor, start now — and treat the existing log as unverifiable
history.

## Routine tasks

### Rotating a key

```bash
algostream-keyctl add --label "operator 2026-09" --scopes read,control
# deploy the new key wherever it is used
algostream-keyctl expire --kid OLDKID --in 24h
algostream-keyctl prune --older-than 30d
```

Both keys work during the overlap, so there is no cutover moment. Audit records keep whichever key
was actually used.

### Backups

```bash
make backup DIR=/var/lib/algostream/audit
```

Then copy `*.anchor` somewhere this machine cannot write. That file is the entire difference between
a corruption check and tamper-evidence.

### Rolling out a new build

```bash
make docker-release
scripts/blue-green.sh --image algostream:v2
scripts/blue-green.sh --rollback     # if it goes wrong
```

The manifests and this script have been applied to a single-node kind cluster and observed working
end to end, including a promotion and a rollback. Multi-node is unproven. Read
`scripts/blue-green.sh` before trusting it, and expect the `ReadWriteOnce` audit volume to block a
cross-node handover — see the [deployment guide](deployment.md) for what a real cluster found.

## Measuring performance

```bash
make paced-bench RATE=50000
```

This offers a fixed rate and reports latency under it — the figure the 5 ms target is about
(p99 ≈ 0.15 ms).

**Do not compare it to `event_bus_latency`.** That benchmark publishes as fast as it can, so the
producer outruns the dispatcher and it measures queueing delay at saturation — double-digit
milliseconds by construction. Its metrics are named `event_bus.saturated_queueing.*` for that
reason. Both numbers are real; they answer different questions.

If the paced run prints `publisher averaged N ns behind schedule`, the machine could not offer the
requested rate and the latency figures include that shortfall rather than measuring the bus.
