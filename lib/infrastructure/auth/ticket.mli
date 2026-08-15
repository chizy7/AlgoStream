(** Single-use tickets for the event stream.

    {1 Why the stream needs its own credential}

    Everything else authenticates with [Authorization: Bearer], and that choice does more work than
    it looks like it does. A cross-origin [fetch] that sets [Authorization] is not a CORS simple
    request, so it triggers a preflight; the server sends no [Access-Control-Allow-*] headers, the
    preflight fails, and the request is never sent. A page the operator happens to have open in
    another tab therefore cannot forge a control action — a complete CSRF defence with no CSRF
    machinery, no tokens to double-submit and no [SameSite] reasoning.

    {b This is precisely why there is no cookie session here.} A cookie is attached by the browser
    automatically, including on a cross-site POST, which would reintroduce the attack the bearer
    header rules out — in order to solve a problem that exists at exactly one endpoint.

    That one endpoint is [/events]. [EventSource] cannot set request headers, so the stream needs a
    credential it can carry in a URL. A ticket is that credential, made weak enough that carrying it
    in a URL does not matter:

    - 128 bits from the OS CSPRNG — not the API key, which never appears in a URL.
    - {b Single use.} Redeemed and deleted when the stream opens; presenting it twice fails.
    - {b 30 seconds.} Replaying one out of a screenshot of the network panel is useless.
    - Bound to the [kid] and scopes of the key that minted it, so the stream can be attributed and
      swept when that key is revoked.
    - Stored as a digest and compared with the same {!Api_key.verify} the keys use, rather than a
      second comparison path that could rot differently.

    The table is capped, and sweeping happens on mint, so a client that requests tickets and never
    connects cannot grow memory. *)

type t

(** Outstanding tickets. Never more than {!capacity}; the oldest is evicted first. *)
val create : unit -> t

val capacity : int

val ttl_ns : int64

(** [mint t ~now_ns ~kid ~scopes] returns the ticket string to hand to the client. *)
val mint : t -> now_ns:int64 -> kid:string -> scopes:Scope.Set.t -> string

(** [redeem t ~now_ns ~ticket] consumes a ticket and returns the principal it was minted for.

    [None] when the ticket is unknown, already used, or older than {!ttl_ns}. The three are
    deliberately not distinguished: the caller answers 401 either way, and saying which would tell
    an attacker whether a guess was ever valid. *)
val redeem : t -> now_ns:int64 -> ticket:string -> Principal.t option

(** Outstanding, unredeemed count. For tests and telemetry. *)
val outstanding : t -> int
