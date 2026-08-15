(** Explicit state-machine helpers on top of [Algostream_domain_orders.Order.order_status].

    The Domain.Order module already has a 7-state status enum (Pending / Open / Partially_filled /
    Filled / Cancelled / Rejected / Expired) but no explicit transition table or terminal-state
    predicates. This module fills that gap as pure functions — [transition] returns the new [status]
    for the caller to apply via [Order.update_status], so we do not inject a wall-clock read into
    our event-time-deterministic layers. *)

module Order = Algostream_domain_orders.Order

type status = Order.order_status

val is_terminal : status -> bool

val is_active : status -> bool

val status_name : status -> string

type transition_error =
  | Invalid_transition of {
      from_ : string;
      to_ : string;
    }
  | Terminal_state of string

(** Legal transitions only.
    - Pending → Open | Cancelled | Rejected
    - Open → Partially_filled | Filled | Cancelled | Rejected | Expired
    - Partially_filled → Partially_filled (more fills) | Filled | Cancelled | Expired
    - Terminal states (Filled, Cancelled, Rejected, Expired) → none *)
val can_transition : from_:status -> to_:status -> bool

(** Returns [Ok new_status] if the transition is valid; the caller applies it via
    [Order.update_status]. Returns [Error] without mutating. *)
val transition : Order.order -> to_:status -> (status, transition_error) Stdlib.result
