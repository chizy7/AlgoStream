# Release image for the AlgoStream daemon.
#
# Distinct from Dockerfile.dev, which is a profiling shell: that image grants passwordless sudo,
# runs with SYS_ADMIN and seccomp:unconfined so perf and valgrind work, and never builds the
# project. All three are correct for development and disqualifying for production.
#
# Debian slim rather than Alpine, which is what docs/guides/performance_tuning.md used to prescribe.
# OCaml against musl is a fight with no measurable latency payoff for this workload, and the runtime
# stage is ~80MB either way once you account for the libraries the binary actually needs. Image size
# is not on the critical path; correctness of the C runtime under a 5.x multicore program is.

# ───────────────────────── build ─────────────────────────
FROM ocaml/opam:debian-12-ocaml-5.6 AS build

USER root
RUN apt-get update && apt-get install -y --no-install-recommends \
      libgmp-dev \
      pkg-config \
      m4 \
      libssl-dev \
    && rm -rf /var/lib/apt/lists/*

USER opam
WORKDIR /build

# Dependencies resolve from the opam file alone, so this layer is cached until the dependency set
# actually changes — not on every source edit.
COPY --chown=opam:opam algostream.opam dune-project ./
RUN opam update && opam install --deps-only --yes .

COPY --chown=opam:opam . .

# Release profile: no debug runtime, assertions off, the flambda settings the profile carries.
RUN opam exec -- dune build --profile release bin/algostream.exe bin/keyctl.exe bin/auditctl.exe

# ───────────────────────── runtime ─────────────────────────
FROM debian:13-slim AS runtime

RUN apt-get update && apt-get install -y --no-install-recommends \
      libgmp10 \
      ca-certificates \
      curl \
    && rm -rf /var/lib/apt/lists/*

# ca-certificates is not optional: the exchange feeds are wss:// and conduit verifies peers against
# the system trust anchors. Without it every outbound connection fails certificate validation, which
# surfaces as a connect timeout rather than anything that names the real cause.

# Numeric uid so a Kubernetes runAsNonRoot check can verify it without resolving a name.
RUN groupadd --system --gid 10001 algostream \
    && useradd --system --uid 10001 --gid algostream --no-create-home --shell /usr/sbin/nologin algostream

WORKDIR /app

COPY --from=build /build/_build/default/bin/algostream.exe /usr/local/bin/algostream
COPY --from=build /build/_build/default/bin/keyctl.exe     /usr/local/bin/algostream-keyctl
COPY --from=build /build/_build/default/bin/auditctl.exe   /usr/local/bin/algostream-auditctl

# From the build context, not the build stage. site/ has no dune file and nothing depends on it, so
# dune never materialises it under _build/default — copying it from there fails the build with
# "not found". It is source, not an artifact.
COPY site /app/site

# Writable by the daemon, and only by it. The audit log is created 0600 regardless; this makes the
# directory match, so a stray umask cannot widen it.
RUN mkdir -p /var/lib/algostream/audit \
    && chown -R algostream:algostream /var/lib/algostream \
    && chmod 700 /var/lib/algostream /var/lib/algostream/audit

USER algostream:algostream

EXPOSE 8080

# The container binds 0.0.0.0 because a loopback bind inside a container is unreachable from outside
# it — the network namespace is the isolation boundary. That is exactly the case check_bind refuses
# by default, so --auth-keys is mandatory here and the daemon will exit 2 without it. Supply a
# keystore and terminate TLS at the ingress; see docs/guides/security.md.
#
# Configuration is CLI flags in CMD, not environment variables. An ENV that nothing reads is worse
# than no ENV: it looks like a supported knob and silently does nothing when set.

# No shell form, so the daemon is PID 1 and receives SIGTERM directly. It installs a handler and
# shuts the bus, processors and runtime down in order.
ENTRYPOINT ["/usr/local/bin/algostream"]
CMD ["--http-host", "0.0.0.0", \
     "--http-port", "8080", \
     "--static", "/app/site", \
     "--auth-keys", "/etc/algostream/keys.json", \
     "--audit-dir", "/var/lib/algostream/audit", \
     "--insecure-plaintext-bind", \
     "--gc-tune"]

# Probes the API rather than merely proving the binary runs. /api/health is the one endpoint that
# stays public — the dashboard uses it to tell a live daemon from a recorded demo — so this needs no
# credential, and it returns 503 rather than 200 when a health check has failed.
HEALTHCHECK --interval=30s --timeout=5s --start-period=20s --retries=3 \
    CMD curl -fsS http://127.0.0.1:8080/api/health || exit 1
