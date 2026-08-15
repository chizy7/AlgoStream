(** Event bus facade.

    Producers call {!publish}; subscribers register handlers via {!subscribe} or
    {!subscribe_filtered}. A background dispatcher [Domain] drains the priority queue and invokes
    handlers synchronously (per-subscription async queues are a planned follow-up). *)

type t

(** [create ?capacity_per_band ?sla_ns ()] allocates a bus with the given per-band ring-buffer
    capacity (default 4096) and SLA threshold for the instrumentation layer (default 5ms). The bus
    is created in stopped state; call {!start} to spin up the dispatcher. *)
val create : ?capacity_per_band:int -> ?sla_ns:int64 -> unit -> t

val start : t -> unit

(** [stop t] signals the dispatcher to drain its current band and exit, then joins the dispatcher
    domain. Safe to call from any thread; safe to call twice. Registered as an [at_exit] hook on
    first {!start}. *)
val stop : t -> unit

(** Non-blocking publish. Drops the event and returns [false] if the matching priority band is full.
    Either outcome is counted; see {!flow_stats}. *)
val try_publish : t -> Event_types.Event.t -> bool

(** Non-blocking publish that ignores overflow. Convenience wrapper.

    Ignoring the result does not hide the loss: the drop is still counted in {!flow_stats}. *)
val publish : t -> Event_types.Event.t -> unit

val subscribe : t -> (Event_types.Event.t -> unit) -> Subscription.subscription_id

val subscribe_filtered :
  t -> Subscription.Filter.t -> (Event_types.Event.t -> unit) -> Subscription.subscription_id

val unsubscribe : t -> Subscription.subscription_id -> unit

val subscriber_count : t -> int

(** Total in-flight count summed across all bands. *)
val depth : t -> int

(** Per-band in-flight count, indexed by [Priority.to_int]. A band that sits near capacity is about
    to start dropping. *)
val depth_per_band : t -> int array

val instrumentation : t -> Instrumentation.t

val stats : t -> Instrumentation.stats

(** Cumulative flow counters since {!create}.

    [dispatched] counts events popped and delivered, so [total_published - dispatched] is the amount
    still in flight or lost to shutdown. [handler_errors] counts exceptions raised by subscriber
    handlers: the dispatcher swallows them so one bad subscriber cannot stall the bus, but a
    subscriber that raises on every event would otherwise be completely invisible. *)
type flow_stats = {
  published_per_band : int64 array;
  dropped_per_band : int64 array;
  total_published : int64;
  total_dropped : int64;
  dispatched : int64;
  handler_errors : int64;
}

(** Read the counters. Cheap and safe from any Domain; each field is read independently, so the
    snapshot is not a consistent cut across counters. *)
val flow_stats : t -> flow_stats
