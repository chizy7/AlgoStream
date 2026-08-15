# Security Policy

## Scope

AlgoStream is **paper-trading research infrastructure**. There is no venue connectivity anywhere in
the project — no exchange credentials, no request signing, no trading endpoint — so no vulnerability
here can move funds. What the security model protects is the **control surface and the data**: the
dashboard API can start, pause, stop and reallocate strategies, and it serves live position and P&L
figures.

The threat model, including the adversaries explicitly considered out of scope, is documented in
[docs/guides/security.md](docs/guides/security.md).

## Reporting a vulnerability

Please report security issues **privately**, not as a public GitHub issue.

- Use [GitHub's private vulnerability reporting](https://github.com/chizy7/AlgoStream/security/advisories/new)
  on this repository, or
- email **chizy@chizyhub.com** with `SECURITY` in the subject.

Please include the version or commit, what an attacker gains, and a reproduction if you have one.

This is a single-maintainer open-source project, so there is no formal SLA. Expect an initial
response within a week. If a report is valid, the fix and the advisory land together.

## What is in scope

- Authentication and authorization bypass — reaching a `control`-scoped route without a
  `control`-scoped key, or any route without a credential when a keystore is configured.
- Forging, replaying or escalating an event-stream ticket.
- Defeating the audit log's tamper-evidence in a way the documented threat model does not already
  admit. **Note the chain is unkeyed by design**: anyone who can write the log file can recompute
  it. That is why an out-of-band anchor (`algostream-auditctl head`) is required, and it is
  documented rather than treated as a defect. Truncating the tail of a log is likewise a known
  limitation, with a test asserting it.
- Path traversal or unintended file exposure through the static file handler.
- Credential disclosure — a key reaching a log, an error message, or a URL.
- Any way to make the daemon bind a non-loopback address without a keystore, which it is supposed to
  refuse.

## What is not in scope

These are deliberate design positions, argued in the security guide:

- **A process running as the same uid.** It can read the keystore, `ptrace` the daemon and read
  `/proc/net/tcp`. No HTTP-layer mechanism defends against this.
- **No inbound TLS.** Serving HTTPS on loopback defends only against an attacker who already has
  root, while adding a self-signed certificate interstitial that trains operators to click through
  TLS warnings. A non-loopback bind is refused unless TLS is terminated by a reverse proxy.
- **Unsalted SHA-256 for API key storage.** The input is 256 bits of CSPRNG output, so a password
  KDF makes no attack harder and only adds latency. The reasoning is in
  `lib/infrastructure/auth/api_key.mli`.
- **`X-Forwarded-For` is not trusted or parsed.** Behind a proxy, audit records show the proxy's
  address.
- Findings in the Kubernetes manifests under `k8s/`, which are schema-validated only and documented
  as never having been applied to a cluster.

## Handling credentials

API keys are shown once at creation and stored only as a SHA-256 digest — a lost key is regenerated,
not recovered. The keystore must be mode `0600` and owned by the running user; the daemon **refuses
to start** otherwise rather than warning.

If you believe a key has been exposed:

```bash
algostream-keyctl revoke --kid KID
```

Revocation takes effect within one second, and open event streams are dropped on the next push tick.
