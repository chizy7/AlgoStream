# Deployment Guide

Running AlgoStream outside a development shell: the release container, the observability stack, and
the Kubernetes manifests — with an explicit note on which of these has actually been exercised.

**Verification status, up front.** The container and the compose stack are run end to end and work.
The Kubernetes manifests and the blue/green script have been **applied to a single-node kind
cluster** and observed working: the pod reaches Ready through its own `/api/health` probes, the
Service serves it, and a promotion and a rollback both complete without the Service losing its
endpoint. Multi-node is still unproven — see below. Where a number appears — CPU, memory, timeouts —
it is reasoned from the benchmarks rather than measured under production load.

This remains paper trading throughout. There is no venue connectivity in this project.

## The release container

`Dockerfile` is a multi-stage build; `Dockerfile.dev` is something else entirely and is left alone.

|  | `Dockerfile` | `Dockerfile.dev` |
|---|---|---|
| Builds the project | yes | **no** |
| User | `algostream` (uid 10001) | `opam`, passwordless sudo |
| Capabilities | all dropped | `SYS_ADMIN`, `PERFMON` |
| seccomp | default | `unconfined` |
| Purpose | production | perf, valgrind, gdb |

The dev image's privileges are correct for profiling and disqualifying for anything unattended.
Never derive a production image from it.

```bash
make docker-release
```

Debian slim, not Alpine — which is what the tuning guide used to prescribe. OCaml against musl is a
fight with no measurable latency payoff for this workload, and the runtime layer lands around the
same size once the libraries the binary actually needs are accounted for.

`ca-certificates` is not optional in the runtime stage: the exchange feeds are `wss://` and conduit
verifies peers against the system trust anchors. Without it every outbound connection fails
certificate validation, which surfaces as a connect timeout rather than anything naming the cause.

Configuration is CLI flags in `CMD`. There are no environment variables, deliberately — an `ENV`
nothing reads looks like a supported knob and silently does nothing when set.

### Why the container must bind `0.0.0.0`

A pod or container's loopback is unreachable from outside its network namespace; the namespace *is*
the isolation boundary. So the daemon binds `0.0.0.0`, which is exactly the case `check_bind`
refuses by default. That means:

- `--auth-keys` is **mandatory** in a container. Without it the daemon exits 2.
- `--insecure-plaintext-bind` is in the default `CMD`, on the assumption that TLS is terminated at
  the ingress. If it is not, fix that before exposing the port.

## The observability stack

```bash
make stack-up      # daemon + Prometheus + Grafana + Alertmanager
make stack-down
```

| Service | URL |
|---|---|
| Dashboard | `http://127.0.0.1:8080/dashboard/` |
| Prometheus | `http://127.0.0.1:9090` |
| Grafana | `http://127.0.0.1:3000` |
| Alertmanager | `http://127.0.0.1:9093` |

Every port binds `127.0.0.1` explicitly. Grafana runs with anonymous viewer access because the
alternative is a default admin password committed to the repository; do not expose 3000 without
changing that.

`make stack-up` generates a keystore and a read-scoped scrape key on first run. The scrape token is
written **without a trailing newline** — Prometheus sends the file's bytes verbatim, and a newline
makes every scrape 401 with an error that does not mention whitespace.

`/metrics` is gated on the `read` scope like every other observation endpoint. Leaving it open would
make it the one unauthenticated hole in an otherwise authenticated surface, and it carries the same
telemetry the dashboard shows.

### Alert rules

The nine rules in `monitoring/prometheus/rules/` are derived from the conditions
`lib/telemetry/alert.ml` already evaluates in-process, so the two agree rather than drifting into
separate opinions about what "unhealthy" means.

**One thing to keep in mind.** Latency is measured as `now - event.timestamp_ns`, so it is only
meaningful on a live source. A replayed log reports the age of the log and would trip every latency
rule on every event. The daemon disables in-process latency alerting when replaying; Prometheus
cannot know that. Do not point a scrape at a replay run and believe the result.

```bash
make k8s-validate   # kubeconform over k8s/, promtool over the rules
```

## Kubernetes

```bash
kubectl create secret generic algostream-keys --from-file=keys.json
kubectl apply -f k8s/
```

The `Secret` in `service.yaml` is a **template carrying no key material**. Generate a real keystore
with `algostream-keyctl` and create the Secret from it; committing a key would put a credential in
git history, where it survives deletion.

### What applying it to a real cluster found

Worth recording, because all three passed `kubeconform -strict` and `kubectl --dry-run=client` and
none of them is a schema error:

1. **The container args used `--flag=value`.** The daemon's hand-rolled parser matched exact flag
   strings and took the next argv element, so every pod died at startup with
   `unknown argument --http-host=0.0.0.0`. The parser now accepts both spellings
   (`Common_utils.Cli.expand_equals`), since the `=` form is what manifests, systemd units and
   compose files are conventionally written in.
2. **`fsGroup` made the keystore unreadable by its own permission check.** A Secret volume is owned
   by root, and setting `fsGroup` — which the audit PVC needs so a non-root user can write to it —
   makes the kubelet add group-read to every volume in the pod, so `defaultMode: 0400` arrives as
   0440. The check refused both, which made the keystore impossible to mount in *any* pod. It now
   refuses what is actually an exposure — world access, or a group that is not ours — rather than
   any deviation from mode 0600.
3. **The Secret mount reads as world-writable.** It is mounted read-only, so nothing can write there
   whatever the mode bits say. The directory check now tests writability directly with `access`
   instead of inferring it from the bits.

### Liveness and health are different questions

`livenessProbe` uses **`/api/live`**; `startupProbe` and `readinessProbe` use `/api/health`. That
split is load-bearing, and getting it wrong is a self-inflicted outage.

`/api/health` aggregates every subsystem, so a single unreachable exchange takes it to 503 and holds
it there once the circuit breaker opens. Measured with Binance geo-blocked: 200 (`degraded`) at 15
seconds, 503 (`failed`) from 45 seconds onward, permanently. With liveness pointed at it —
`failureThreshold: 3` at `periodSeconds: 30` — Kubernetes would kill the pod about 90 seconds into
any feed outage, restart it, watch it fail identically, and CrashLoop forever on a dependency no
restart can fix.

Liveness answers only "is this process wedged?". Readiness answers "should this pod take traffic?",
and a degraded feed genuinely should take it out of service. `/api/live` returns 200 whenever the
HTTP server can run its handler, and carries a `note` field saying so, to discourage anyone wiring
alerting to it.

### Resource reservations

Requests **equal** limits, which is what the phrase means in practice: it places the pod in the
Guaranteed QoS class, so the kubelet will not evict it ahead of burstable neighbours under node
pressure, and the CPU is not subject to CFS throttling in the middle of a dispatch tick.

### Replicas is 1, and that is not an oversight

The daemon is not horizontally scalable as written. Each instance opens its own exchange
connections and runs its own copy of the strategy, so two replicas means duplicate subscriptions and
two independent paper portfolios — not shared load. Blue/green provides availability across a
*deploy*; it does not make this a clustered system.

### Blue/green

```bash
scripts/blue-green.sh --image algostream:v2
scripts/blue-green.sh --rollback
```

**`--rollback` used to cause an outage.** A completed promotion scales the old slot to zero, and the
rollback path flipped the Service selector straight to it — leaving the Service with no endpoints
and requests failing to connect, from the one command whose purpose is avoiding exactly that. It now
scales the target up and waits for a ready pod before flipping. It still applies no health gate:
gating a rollback on the check that is already failing would be backwards. If the target does not
become ready within the timeout it flips anyway and says so, because an unconditional rollback is
what the command promises.

The script scales the inactive slot up, waits for the rollout, **health-gates it against its own
Service before it takes any traffic**, flips the main Service selector, waits 30 s for in-flight
connections to drain, then scales the old slot down. Flipping a selector is instant and
unconditional, so without that gate a broken build takes traffic the moment it is applied.

`--rollback` deliberately skips the gate: a rollback is what you reach for when things are already
wrong, and making it conditional on the failing health check would be exactly backwards.

**A real constraint:** the audit volume is `ReadWriteOnce`, and both slots mount it. On a single
node the handover works. Across nodes, green cannot start until blue releases the volume. Either pin
both slots to one node, use a `ReadWriteMany` storage class, or accept a brief gap. This is a
property of the design, not a bug to be worked around silently.

## Backup and recovery

```bash
make backup DIR=/var/lib/algostream/audit
scripts/restore.sh --archive backups/algostream-….tar.gz --into /tmp/restored
```

`backup.sh` verifies the chain **before** archiving and refuses on a break — an archive of an
already-broken chain preserves the tampering rather than the evidence of what the log said
beforehand, and you find out months later. `--force` overrides, which is right when the break is
what you are trying to preserve.

`restore.sh` refuses to overwrite a non-empty target, because restoring over a live audit log during
an incident is the most common way one gets destroyed.

**Copy the anchor off the machine.** `backup.sh` writes the head hash next to each archive. The
chain is unkeyed, so a rewritten log verifies perfectly; only comparing against a hash the daemon
cannot reach distinguishes "the log that was backed up" from "a log". See the security guide.

## Tuning

Both flags default off, because both are pessimisations on a machine you do not own.

```bash
algostream --gc-tune --pin-cores 2,3,4,5,6,7
```

`--gc-tune` sets a 16 MiB minor heap and `space_overhead 80`. OCaml 5's minor collections are
stop-the-world across every Domain, so each one pauses the bus dispatcher, all three processors and
the runtime at once; fewer, larger minor collections is the whole game.

`--pin-cores` assigns cores to Domains in spawn order — dispatcher, then the processor drain loops,
then the runtime, then the Lwt host. **Linux only.** On macOS it warns and continues unpinned rather
than reporting a success it did not achieve.

NUMA binding is not in-process; use a launcher:

```bash
numactl --cpunodebind=0 --membind=0 algostream --pin-cores 2,3,4,5
```

See `docs/guides/performance_tuning.md` for the machine-level settings, which need root and are the
operator's job rather than the process's.
