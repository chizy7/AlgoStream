(** Who is making a request.

    Deliberately lives here rather than in the network library: the dependency runs
    [network -> auth] and never back. Nothing in this library knows that HTTP exists — it takes
    strings and returns results — which is what makes it testable without a socket. *)

type t =
  | Anonymous
    (** No credential was presented. Reaches a handler only on a route declared {!Scope.Public}. *)
  | Key of {
      kid : string;  (** public key id — safe to log and to write into an audit record *)
      label : string;  (** the operator's own description, as the keystore read at that moment *)
      scopes : Scope.Set.t;
    }

(** The key id, or ["-"] for {!Anonymous}. Never [None], because every audit record needs an actor
    column and a missing value there should read as "nobody" rather than as an absent field. *)
val kid : t -> string

val label : t -> string

val scopes : t -> Scope.Set.t

(** [has t scope] is {!Scope.satisfies} against this principal's grants. *)
val has : t -> Scope.t -> bool

(** Flat fields for [/api/whoami] and for audit records. Contains no secret — by construction, since
    a principal never carries one. *)
val to_assoc : t -> (string * string) list

val to_string : t -> string
