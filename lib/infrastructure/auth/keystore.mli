(** The key file, and authentication against it.

    {1 On disk}

    {v
    {
      "version": 1,
      "keys": [
        { "kid": "a1b2c3d4",
          "label": "laptop dashboard",
          "scopes": ["read", "control"],
          "hash": "sha256:6f4b...c21e",
          "created_ns": 1754400000000000000,
          "expires_ns": null,
          "revoked_ns": null }
      ]
    }
    v}

    Only hashes are stored. A key that is lost is regenerated, not recovered.

    {1 Loading refuses rather than warns}

    {!load} returns [Error] — never a warning — when the file is group- or world-readable, is owned
    by someone other than the effective user, sits in a world-writable directory, is malformed,
    names an unknown scope, or repeats a [kid].

    Failing closed is the point. A keystore the whole machine can read is not a keystore, and a
    daemon that runs detached is a daemon whose warnings nobody reads. The one place this yields is
    the cached reload described below.

    {1 Rotation and revocation}

    Rotation is an overlap window and nothing more. Add a key, set [expires_ns] on the old one a day
    out, and both authenticate until the clock passes it. Nothing has to be coordinated and there is
    no moment where neither key works. Audit records keep whichever [kid] was actually used, so the
    changeover stays legible afterwards.

    Revocation sets [revoked_ns], which takes effect immediately regardless of [expires_ns].

    The daemon holds the store in memory, so a change on disk is not instantaneous. {!authenticate}
    re-[stat]s at most once a second and reloads when the file's mtime or size moved — one [stat]
    per second at dashboard volumes, no watcher fiber and no signal handling.
    {b Revocation therefore takes effect within one second}, which is stated here because an
    operator revoking a key deserves to know the number.

    A reload that {i fails} keeps the previous good store and logs. That is the deliberate exception
    to failing closed: locking the operator out of a running trading system because of a stray comma
    is worse than running a one-second-stale policy. *)

type t

type record = {
  kid : string;
  label : string;
  scopes : Scope.Set.t;
  hash : string;
  created_ns : int64;
  expires_ns : int64 option;
  revoked_ns : int64 option;
}

(** Why authentication failed. Separated because the dispatcher maps them to different responses:
    everything here is a 401 except {!Insufficient_scope}, which is a 403 — the credential was good
    and the answer is still no. *)
type failure =
  | Malformed of string
  | Unknown_key
  | Expired
  | Revoked
  | Insufficient_scope of Scope.t

val failure_to_string : failure -> string

(** Path this store was loaded from. *)
val path : t -> string

(** Load and validate. See the interface header for every condition that is refused. *)
val load : string -> (t, string) result

(** An empty in-memory store bound to [path], for tests and for [--no-auth]. *)
val empty : string -> t

val records : t -> record list

(** [save path records] writes atomically: a temporary file in the same directory, created [0o600]
    with [O_EXCL], [fsync]ed, then [rename]d over the target. There is no window in which the
    keystore exists but is truncated. *)
val save : string -> record list -> (unit, string) result

(** [authenticate t ~now_ns ~credential ~required] resolves a wire credential to a principal.

    Reloads from disk first when the cached copy is more than a second old and the file changed. An
    unknown [kid] still runs a digest against {!Api_key.dummy_hash}, so the response time does not
    distinguish "no such key" from "wrong secret". *)
val authenticate :
  t -> now_ns:int64 -> credential:string -> required:Scope.t -> (Principal.t, failure) result

(** [is_live t ~now_ns ~kid] — is this key still neither expired nor revoked?

    The event stream needs this: a connection opened before a revocation would otherwise outlive it,
    quietly streaming positions to a credential that no longer exists. The push loop re-checks each
    live stream against this. *)
val is_live : t -> now_ns:int64 -> kid:string -> bool

(** Build a record for a freshly generated key. *)
val make_record :
  kid:string ->
  label:string ->
  scopes:Scope.Set.t ->
  secret:string ->
  now_ns:int64 ->
  expires_ns:int64 option ->
  record
