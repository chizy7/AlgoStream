(** What a credential is allowed to do.

    Two grantable scopes and no more. The dashboard has one operator watching one process, so the
    only distinction that carries weight is {i observing} versus {i changing}: a key pasted into a
    browser tab to watch P&L should not be able to stop a strategy.

    Per-resource scoping — [control:pairs-1] and friends — was considered and rejected. It is the
    right shape for a multi-tenant service with many operators and many instances, and this is
    neither. Adding it would mean an ACL to administer for a system where the answer is always "yes,
    the operator". *)

type t =
  | Public  (** no credential at all. Reserved for [/api/health] — see {!val:satisfies}. *)
  | Read  (** telemetry, strategies, positions, P&L, reports, the event stream *)
  | Control  (** pause, resume, stop, reallocate *)

(** Scopes as they appear in a keystore record and on the wire. [Public] is deliberately absent: it
    is a property of a route, not something a key can hold, and accepting it here would let a
    keystore grant a scope that means "no credential required". *)
val of_string : string -> (t, string) result

val to_string : t -> string

(** The set of scopes a key holds. *)
module Set : sig
  type scope := t

  type t

  val empty : t

  val of_list : scope list -> t

  val to_list : t -> scope list

  val mem : t -> scope -> bool

  val to_string : t -> string
end

(** [satisfies ~granted ~required] decides one request.

    [Control] implies [Read] — a key that may stop a strategy may obviously look at one, and making
    operators list both would only invite a keystore that grants control without read. [Public] is
    satisfied by anything, including the empty set, which is what lets an unauthenticated health
    probe through the same code path as everything else rather than around it. *)
val satisfies : granted:Set.t -> required:t -> bool
