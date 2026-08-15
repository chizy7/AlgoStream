(** One audit entry, and its canonical byte encoding.

    {1 What a record has to carry}

    Enough to answer "who changed what, when, and did it work" without a second lookup. In
    particular both [body_sha256] and [body_excerpt]: the allocation endpoint carries its
    interesting value in the request body, so a record without it says a reallocation happened but
    not to what. The excerpt makes the common case readable; the digest still covers a body larger
    than the excerpt.

    [label] and [scopes] are snapshotted {b at the time of the action}, not looked up when the log
    is read. Relabelling or rescoping a key later must not rewrite history.

    {1 Why the encoding is defined here rather than reusing bin_prot}

    The chain in {!Audit_log} hashes {!canonical}, not a bin_prot serialisation. Coupling
    tamper-evidence to a serialisation library's internal layout would mean a library upgrade could
    silently invalidate every historical record, or — worse — quietly change what a hash commits to.

    Every variable-length field is length-prefixed, and that is load-bearing rather than tidiness:
    without it [("ab", "c")] and [("a", "bc")] encode to identical bytes, and an attacker could move
    a field boundary without disturbing the hash. *)

type outcome =
  | Allowed
  | Denied of string  (** ["no credential"], ["insufficient scope"], ["rate limited"], … *)
  | Failed of string  (** the handler raised, or answered 5xx *)

val outcome_to_string : outcome -> string

type t = {
  seq : int64;  (** 1-based and gapless within a file; a gap is evidence, not an accident *)
  ts_ns : int64;  (** wall clock — an audit trail is read against real time, unlike event time *)
  kid : string;  (** ["-"] when anonymous *)
  label : string;
  scopes : string;  (** comma-joined, as evaluated at the time *)
  peer : string;  (** ["127.0.0.1:54321"] *)
  meth : string;
  path : string;  (** the concrete path, e.g. ["/api/strategies/pairs-1/stop"] *)
  route : string;  (** the pattern, e.g. ["/api/strategies/:id/stop"] *)
  params : (string * string) list;  (** sorted by key before encoding *)
  body_sha256 : string;
  body_excerpt : string;  (** first {!excerpt_bytes} bytes of the body *)
  outcome : outcome;
  status : int;
}

val excerpt_bytes : int

(** Build a record, hashing and truncating [body] and sorting [params]. [seq] is assigned by the
    writer, so it is [0L] here. *)
val make :
  ts_ns:int64 ->
  kid:string ->
  label:string ->
  scopes:string ->
  peer:string ->
  meth:string ->
  path:string ->
  route:string ->
  params:(string * string) list ->
  body:string ->
  outcome:outcome ->
  status:int ->
  t

(** The bytes the hash chain commits to. Injective: see the interface header. *)
val canonical : t -> string

(** A single line for [auditctl tail] and for humans. Not the hashed form. *)
val to_line : t -> string
