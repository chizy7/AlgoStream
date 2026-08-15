(** Multi-band lock-free priority queue.

    A fan of [Priority.num_bands] independent ring buffers. Producers push into the band matching
    the event's priority; consumers always drain the highest-priority non-empty band first.

    The current implementation uses strict priority — band [Critical] must be fully empty before
    band [High] is consulted. This is the simplest correct behavior; it admits theoretical
    starvation of [Low] under sustained [Critical] traffic. A round-robin token scheme can be added
    later. *)

type 'a t

(** Create a priority queue. [capacity_per_band] is the bound on the in-flight count per priority
    band; pushes that would overflow return [false]. *)
val create : capacity_per_band:int -> dummy:'a -> 'a t

(** Non-blocking push. Returns [false] if the band is full. *)
val try_push : 'a t -> Event_types.Priority.t -> 'a -> bool

(** Non-blocking pop of the highest-priority pending event. Returns [None] if every band is empty.
*)
val try_pop : 'a t -> ('a * Event_types.Priority.t) option

(** Total in-flight count summed across all bands. *)
val size : 'a t -> int

val is_empty : 'a t -> bool

(** Per-band depth, indexed by [Priority.to_int]. *)
val depth_per_band : 'a t -> int array
