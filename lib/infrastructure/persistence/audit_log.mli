(** Append-only, hash-chained audit log.

    {1 Why this is not [Event_log]}

    [Event_log] already frames records with a length and a CRC32 and reads back independently, so
    reusing it looks obvious. Four things rule it out, each on its own sufficient:

    - {b It truncates on open.} [Event_log.Writer.create] opens with [O_TRUNC], so a daemon restart
      would empty the audit trail. Changing that flag would change semantics for every existing
      caller, including the deterministic replay fixtures.
    - {b [Event.t] has no actor.} Adding one is not the safe kind of bin_prot change: appending a
      variant constructor preserves compatibility, altering the record does not, and every v2/v3
      fixture would need regenerating.
    - {b Different durability.} Audit wants [fsync] per control action; the event firehose runs at
      tens of thousands of events a second and deliberately does not.
    - {b Different threat model, and this is the real one.} CRC32 detects corruption. It is
      trivially forgeable — anyone who can edit a record recomputes the checksum. Tamper-evidence
      needs a hash chain. And [Event_log.Reader.iter] stops {i silently} at the first bad frame,
      which is exactly backwards here: silent truncation is the tamperer's preferred outcome, so
      this reader reports the break instead.

    The framing {i shape} is borrowed on purpose, so the two files read as siblings.

    {1 The chain}

    {v
    hash_0 = SHA-256("algostream-audit-v1\x00" || prev_file_hash)
    hash_n = SHA-256(hash_(n-1) || canonical_n)
    v}

    On disk each frame is [u32 length | canonical | 32-byte hash]. The previous hash is not stored
    alongside — it {i is} the previous frame's hash, and writing it twice would create a second
    thing that can disagree with the first.

    Files rotate daily as [audit-YYYYMMDD.log]. Each header carries the previous file's final hash
    and name, so the chain survives rotation and {!Verify.directory} can walk a whole directory.

    {1 What this cannot do, and what the anchor is for}

    Read on its own, [verify] catches a modified record, a deleted interior record and a spliced-in
    frame — each shows up as a chain mismatch at the first record the attacker did not also rewrite.

    But the chain is {b unkeyed}, so anyone who can write the file can recompute every hash from the
    point they changed onward and hand you a file that verifies perfectly. Two consequences follow,
    and both are real:

    - {b Tail truncation is invisible.} Deleting the last k records leaves a valid chain.
    - {b So is any rewrite}, if the attacker bothers to redo the hashes after it. Replacing the sole
      record of a single-record log is the degenerate case: with the same genesis hash, the forged
      frame is indistinguishable.

    So the chain's actual guarantee is narrower than "the file is tamper-proof", and stating it
    plainly matters more than the property sounding strong: {i any} change to the log moves the head
    hash. That is what makes it evidence.

    Which is why the out-of-band anchor is not optional. [algostream-auditctl head] prints the
    current sequence number and head hash; record it somewhere the daemon — and therefore anyone who
    compromises the daemon — cannot write. A later [verify] compared against that anchor closes
    every gap above. Without an anchor this is a corruption check with good manners, not
    tamper-evidence.

    HMAC-chaining with a secret was considered and rejected: the key would have to live on the
    machine the attacker owns, so it moves the problem rather than solving it.

    This log is {b not certified} against any regulatory regime. It is a defensible record of
    control actions, not a compliance claim. *)

val magic : int32

val version : int32

val header_size : int

(** Append-only writer. One per directory; not thread-safe, so the daemon owns exactly one and calls
    it from the single dispatcher fiber. *)
module Writer : sig
  type t

  (** [open_ dir] opens today's file in [dir], creating the directory if absent.

      Opens [O_APPEND | O_CREAT] and mode [0o600] — never [O_TRUNC]. An existing file is continued:
      the sequence counter and chain head are recovered by reading it, so a restart extends the
      chain rather than starting a new one. *)
  val open_ : string -> (t, string) result

  (** Append one record, assigning its [seq]. [fsync]s before returning when [sync] is [true], which
      the daemon sets for control actions. *)
  val append : t -> ?sync:bool -> Audit_record.t -> (unit, string) result

  val close : t -> unit

  (** Sequence number of the last record written. [0L] on an empty log. *)
  val last_seq : t -> int64

  (** Current chain head, hex. This is the value to anchor out of band. *)
  val head_hash : t -> string

  val path : t -> string
end

module Reader : sig
  (** [fold path ~init ~f] over every record in one file.

      Stops at the first chain break and reports it rather than returning quietly. *)
  val fold : string -> init:'a -> f:('a -> Audit_record.t -> 'a) -> ('a, string) result
end

module Verify : sig
  type report = {
    file : string;
    records : int;
    first_seq : int64;
    last_seq : int64;
    head_hash : string;  (** hex; compare against an out-of-band anchor *)
    broken_at : int64 option;  (** sequence number of the first record that fails *)
    reason : string option;
  }

  val report_to_string : report -> string

  (** Recompute the chain for one file from its genesis. *)
  val file : string -> (report, string) result

  (** Walk [audit-*.log] in a directory in order, checking that each file's recorded previous-hash
      matches the preceding file's head. Rotation must not be a place the chain can be broken
      without noticing. *)
  val directory : string -> (report list, string) result
end
