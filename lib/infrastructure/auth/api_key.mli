(** Generating, parsing and verifying API keys.

    {1 Shape}

    {v ask_<8 hex>_<52 base32 chars, alphabet a-z2-7> v}

    Written with placeholders rather than a realistic-looking sample on purpose: a plausible string
    here trips secret scanners on every pull request, and a reader skimming for the format should
    not have to wonder whether they are looking at a live credential.

    - [ask_] — a fixed prefix, so the credential is greppable by secret scanners and unmistakable in
      a paste or a bug report.
    - [a1b2c3d4] — the {b key id}, 4 bytes as hex. Public by design. It indexes the keystore and it
      is what appears in audit records and log lines, so a record can name a key without naming the
      secret.
    - the remainder — 256 bits from the OS CSPRNG, base32.

    Base32 rather than base64 because the alphabet has no ['+'], ['/'] or ['=']: the string survives
    a URL, a shell argument and a double-click selection unchanged. There is no checksum character.
    One would catch a typo, but this is pasted rather than transcribed, and the failure mode of a
    typo is already a clean 401.

    {1 Randomness}

    Keys come from {!Mirage_crypto_rng_unix.getrandom}, which reads the OS CSPRNG directly —
    [getrandom] on Linux, [getentropy] on macOS. It needs no [initialize] call and touches no
    process-global RNG state, which matters in a process that documents a single-scheduler
    invariant: key generation adds nothing global.

    {b [Algostream_rng] must never be used here.} It is a reproducible xoshiro PRNG whose entire
    purpose is determinism — CI enforces its use in the simulation layers — and a predictable
    credential is not a credential.

    {1 Storage}

    The keystore holds [sha256:<hex>], unsalted and uniterated. That is the correct choice here and
    would be the wrong one for passwords; the difference is the input distribution. A password KDF
    such as argon2 or bcrypt exists to make each {i guess} expensive, because the guess space is
    small enough to enumerate. Here the input is 256 bits of CSPRNG output: there is no dictionary,
    no reuse across sites, and nothing memorable to exploit. Stretching it would add latency to
    every request and make no attack harder. This is the same reasoning behind treating a personal
    access token differently from a password.

    A pepper was considered and rejected — it would have to live in the same file as the hashes.

    Comparison goes through [Digestif.SHA256.equal], which that library documents as constant-time.
    [Digestif.SHA256.unsafe_compare], one line above it in the same interface, is flagged as
    leaking; a CI lint bans it under this directory. *)

type parsed = {
  kid : string;  (** 8 lowercase hex characters *)
  secret : string;  (** the base32 tail, exactly {!secret_chars} characters *)
}

val prefix : string

val kid_chars : int

val secret_chars : int

(** [generate ()] mints a fresh key. Returns the wire string — show it to the operator once, it is
    never recoverable afterwards — and its parsed parts for immediate storage. *)
val generate : unit -> string * parsed

(** Split a wire string. [Error] on a missing prefix, the wrong number of segments, a [kid] that is
    not hex, or a secret of the wrong length or alphabet. Never raises, so a malformed
    [Authorization] header is a 401 rather than a 500. *)
val parse : string -> (parsed, string) result

(** [hash secret] is the [sha256:<hex>] string stored in the keystore. *)
val hash : string -> string

(** [verify ~secret ~stored] compares in constant time with respect to [secret].

    A [stored] value that is not a well-formed [sha256:<hex>] returns [false] rather than raising —
    a corrupt keystore record must fail closed, not take the daemon down. *)
val verify : secret:string -> stored:string -> bool

(** A digest of a fixed dummy value, for the unknown-[kid] path.

    Running a real comparison against this when no record matches keeps the response time for "no
    such key id" indistinguishable from "wrong secret". The [kid] is public, so this leaks little
    either way, but removing a timing oracle costs two lines. *)
val dummy_hash : string
