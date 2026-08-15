(** Filter combinators and subscription handles. *)

type subscription_id = private int

(** Compose a predicate over [Event.t]. Filters compile to closures evaluated once per dispatch, so
    they stay zero-allocation in the common case. *)
module Filter : sig
  type t

  val any : t

  val by_priority : Event_types.Priority.t -> t

  (** [min_priority p] matches events whose priority is at least as urgent as [p] (i.e.
      [Priority.to_int e.priority <= Priority.to_int p]). *)
  val min_priority : Event_types.Priority.t -> t

  val by_source : string -> t

  (** Match against the [Zero_copy.MessageType] code derived from the payload. *)
  val by_message_type : int32 -> t

  (** Match if the payload carries the given symbol. Heartbeat/Shutdown/Raw payloads never match. *)
  val by_symbol : string -> t

  val and_ : t -> t -> t

  val or_ : t -> t -> t

  val not_ : t -> t

  val custom : (Event_types.Event.t -> bool) -> t

  val matches : t -> Event_types.Event.t -> bool
end

type t = private {
  id : subscription_id;
  filter : Filter.t;
  handler : Event_types.Event.t -> unit;
}

val create : id:subscription_id -> filter:Filter.t -> handler:(Event_types.Event.t -> unit) -> t

(** Allocator for subscription IDs. Thread-safe. *)
module Id_allocator : sig
  type t

  val create : unit -> t

  val next : t -> subscription_id
end

(** Reveal the integer behind a [subscription_id], for logging only. *)
val id_to_int : subscription_id -> int
