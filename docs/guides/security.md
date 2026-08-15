# Security Guide

How the dashboard API is protected, what the threat model actually is, and the two places where
this project deliberately does less than you might expect.

Everything here concerns the **control surface and the data**, not money. There is no venue
connectivity anywhere in AlgoStream — no credentials, no request signing, no trading endpoint — so
no key described below can move a position anywhere but in a simulation.

## The threat model, stated plainly

Security decisions only make sense against a named adversary, so here are the five that were
considered and what happens to each.

| # | Adversary | In scope | Why |
|---|---|---|---|
| 1 | Another local user account on a shared machine | **Yes** | The keystore is `0600` and the daemon refuses to start if it is not |
| 2 | A process running as the same uid | No | It can read the keystore, `ptrace` the daemon and read `/proc/net/tcp`. No HTTP-layer mechanism helps |
| 3 | **A web page the operator visits in another tab** | **Yes — and it drove the design** | See below |
| 4 | The network | **Yes** | A non-loopback bind without a keystore is refused outright |
| 5 | A passive observer of loopback traffic | No | Requires root or `CAP_NET_RAW`, i.e. already adversary 2 |

**Adversary 3 is the one that matters most, and it is the one people expect loopback binding to
handle.** It does not. Loopback binding alone does not stop a page you have open in another tab
from issuing:

```js
fetch('http://127.0.0.1:8080/api/strategies/pairs-1/stop', { method: 'POST' })
```

CORS stops that page *reading* the response. It does not stop the side effect landing. Binding to
loopback provides no defence at all, because the request originates from your own browser.

## Why there is no cookie session

The fix is that `Authorization: Bearer` is the **only** accepted credential channel.

A cross-origin `fetch` that sets `Authorization` is no longer a CORS "simple request", so the
browser sends a preflight `OPTIONS` first. AlgoStream sends no `Access-Control-Allow-*` headers, the
preflight fails, and the real request is never issued. A request *without* the header is rejected
with 401.

That is a complete CSRF defence with no CSRF machinery — no synchroniser tokens, no double-submit,
no `SameSite` reasoning, no per-browser cookie-prefix quirks.

**A cookie session would throw all of it away.** Browsers attach cookies automatically, including on
a cross-site POST, so it would reintroduce exactly the attack the bearer header rules out. The
server also checks the `Origin` header on `POST`/`PUT` as belt and braces, so the door stays shut
even if a browser mishandles preflight.

## Keys

```
ask_<8 hex>_<52 base32 chars, alphabet a-z2-7>
└┬─┘└──┬───┘└───────────────┬────────────────┘
 │     │                    └ 256 bits from the OS CSPRNG, base32
 │     └ key id. PUBLIC — appears in audit records and log lines
 └ fixed prefix, so secret scanners can find it (they do — see below)
```

The segments above are **placeholders, not a sample.** A realistic-looking string here trips secret
scanners on every pull request, and a reader
skimming the format should never have to wonder whether they are looking at a live credential.

```bash
algostream-keyctl add --label "laptop dashboard" --scopes read,control
algostream-keyctl list
```

The key is printed **once**. Only `sha256:<hex>` is stored; a lost key is regenerated, not
recovered.

### Why plain SHA-256 and not argon2

This is the decision most likely to be questioned, so: the stored value is unsalted, uniterated
SHA-256, and that is correct *here* while being wrong for passwords. The difference is the input
distribution.

A password KDF exists to make each **guess** expensive, because the guess space is small enough to
enumerate. The input here is 256 bits of CSPRNG output — no dictionary, no reuse across sites,
nothing memorable to exploit. Stretching it would add latency to every request and make no attack
harder. This is the same reasoning behind treating a personal access token differently from a
password. A pepper was considered and rejected: it would live in the same file as the hashes.

Comparison uses `Digestif.SHA256.equal`, which is constant-time. `unsafe_compare`, one line above it
in the same interface, is documented as leaking and is banned under `lib/infrastructure/auth/` by a
CI lint.

### Scopes

Two, plus `public`:

| Scope | Covers |
|---|---|
| `read` | telemetry, strategies, positions, P&L, reports, the event stream, `/metrics` |
| `control` | pause, resume, stop, reallocate |

`control` implies `read`. Every route declares its requirement as a **mandatory** field, so a new
endpoint that forgets to declare one fails to compile — with a default, the failure mode is an
endpoint silently inheriting `read`, and the next control endpoint added is exactly where silence
would be expensive.

Per-resource scoping (`control:pairs-1`) was considered and rejected: it is the right shape for a
multi-tenant service with many operators, and this is one operator watching one process.

### Rotation and revocation

Rotation is an overlap window and nothing else:

```bash
algostream-keyctl add --label "operator 2026-08" --scopes read,control
algostream-keyctl expire --kid OLDKID --in 24h
```

Both keys authenticate until the clock passes the expiry, so there is no moment where neither works.
Audit records keep whichever key id was actually used, so the changeover stays legible afterwards.

```bash
algostream-keyctl revoke --kid OLDKID
```

Revocation takes effect **within one second** — the daemon re-`stat`s the keystore at most once a
second and reloads on change. Open event streams are dropped on the next push tick, because a
long-lived stream was authorised once at open and would otherwise outlive its credential.

If a reload *fails* — someone hand-edited the JSON — the daemon keeps serving the last good keystore
and logs an error. Locking an operator out of a running trading system over a stray comma is worse
than a one-second-stale policy. That is the one place this design does not fail closed, and it is
deliberate.

### The keystore file

Loading **refuses**, never warns, when the file is group- or world-readable, is owned by another
user, or sits in a world-writable directory. A daemon that runs detached is a daemon whose warnings
nobody reads.

## The event stream

`EventSource` cannot set request headers, so `/events` cannot use a bearer token. It uses a
single-use ticket instead:

```
POST /api/stream-ticket   (Authorization: Bearer …)  ->  { "ticket": "...", "expires_in_s": 30 }
GET  /events?ticket=...
```

128 bits, single use, 30-second TTL, bound to the minting key's id and scopes, stored as a digest.
Every property exists to make carrying it in a URL not matter: replaying one out of a screenshot of
the network panel is useless.

The API key itself is never put in a query string.

## Binding to a network

| `--http-host` | keystore | Result |
|---|---|---|
| loopback | present | Normal |
| loopback | absent | Runs unauthenticated with a warning — preserves `make dash` and the demo |
| non-loopback | absent | **Exit 2.** No warning |
| non-loopback | present | **Exit 2** unless `--insecure-plaintext-bind` |

That last flag is named to read badly in shell history. That is the point.

### Inbound TLS is deliberately not implemented

Serving HTTPS directly would be a net security **decrease**. On loopback it defends only against an
attacker who already has root — i.e. one who can read the keystore anyway — while adding a
self-signed certificate interstitial that trains the operator to click through TLS warnings. Worse,
`EventSource` to an origin with a certificate error fails outright with no way for the page to
prompt, so the dashboard would silently fall back to polling.

Where TLS genuinely matters is a non-loopback bind, and there the right answer is a reverse proxy
with a real certificate:

```nginx
location / {
    proxy_pass http://127.0.0.1:8080;
    proxy_http_version 1.1;
    proxy_set_header Host $host;
    proxy_set_header Authorization $http_authorization;

    # Required. SSE through a buffering proxy delivers nothing until the buffer fills,
    # which for a 4 Hz stream looks exactly like a hung dashboard.
    proxy_buffering off;
    proxy_read_timeout 3600s;
}
```

Audit records will show the proxy's address as the peer. `X-Forwarded-For` is not trusted and not
parsed — a trusted-proxy list is configuration that has to be right to be safe, and getting it
wrong means an attacker choosing what the audit log records about them.

## The audit trail

Every control action is recorded with attribution: which key, from which peer, against which route,
with what body, and whether it was allowed.

```bash
algostream-auditctl tail /var/lib/algostream/audit
algostream-auditctl verify /var/lib/algostream/audit
algostream-auditctl head /var/lib/algostream/audit
```

Records are chained: `hash_n = SHA-256(hash_(n-1) || canonical_n)`. Any modification invalidates
every hash after it.

**What the chain does not do, and this matters.** It is unkeyed, so anyone who can write the file
can recompute every hash from the point they changed onward and hand you a file that verifies
perfectly. Tail truncation is therefore invisible, and so is a wholesale rewrite.

So the guarantee is narrower than "tamper-proof", and worth stating precisely: **any change to the
log moves the head hash.** That is what makes it evidence — and it is only evidence if you have
recorded the head somewhere the daemon cannot write:

```bash
algostream-auditctl head /var/lib/algostream/audit    # copy this off the machine
```

You can watch it fail for yourself, against a scratch audit directory:

```bash
make backup DIR=/tmp/algostream-audit
truncate -s -200 /tmp/algostream-audit/audit-*.log            # lop off the tail
dune exec bin/auditctl.exe -- verify /tmp/algostream-audit    # still reports "chain intact"
```

`scripts/backup.sh` writes the anchor beside each archive, and `restore.sh --anchor` compares
against it — that is what catches the truncation above. A cleanly truncated log reports "chain
intact" and the anchor catches it anyway; there is a test asserting exactly that, so the limitation
cannot quietly be forgotten.

HMAC-chaining with a secret was considered and rejected: the key would live on the machine the
attacker owns.

**This is not certified** against MiFID II, SEC 17a-4, or any other regime. It is a defensible
record of control actions, not a compliance claim.

## What is out of scope

1. **A process running as your uid.** It reads the keystore directly.
2. **Audit tail truncation**, without an out-of-band anchor. Impossible locally.
3. **Per-resource scopes.** One operator, one instance.
4. **Users, roles, password login.** An API key is the right primitive here.
5. **Encrypting the keystore at rest.** It holds hashes; there is nothing further to protect.
6. **`X-Forwarded-For` trust.** See above.
7. **Shipping audit records to a remote sink.** Local file plus `auditctl`.
