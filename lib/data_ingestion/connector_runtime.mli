(** Generic per-exchange runtime: connect over WebSocket, send the subscribe message, read frames in
    a loop, parse, validate, and publish into the bus. Backoff and circuit-breaking is delegated to
    {!Connection_supervisor}.

    Lives entirely inside the ingestion Lwt Domain — never blocks. The [bus] and [Symbol_intern.t]
    must be alive for as long as [run] is. *)

val run :
  (module Exchange.S) ->
  bus:Algostream_infrastructure_event_bus.Event_bus.t ->
  symbol_intern:Symbol_intern.t ->
  data_quality:Data_quality.t ->
  supervisor:Connection_supervisor.t ->
  rate_limiter:Rate_limiter.t ->
  drop_counter:int64 ref ->
  stop:unit Lwt.t ->
  unit Lwt.t
