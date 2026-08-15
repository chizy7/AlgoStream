(** Bus payload to market record.

    [Event_types.Event.payload] carries transport concerns a strategy has no business seeing —
    sequence ids, priority bands, [Raw of bytes]. [Backtest.Data_source.record] is the market-data
    shape the fill engine and market view already consume, so the live runner translates into that
    and then reuses the whole offline matching path rather than growing a parallel one.

    That reuse is the point: it is what lets {!Algostream_runtime.Instance} and [Backtest.Engine] be
    checked against each other for equal behaviour on equal input. *)

module Data_source = Algostream_backtest.Data_source

(** [None] for payloads that carry no market data — heartbeats, risk alerts, gaps, order lifecycle.
    The caller decides what else to do with those. *)
val of_payload :
  Algostream_infrastructure_event_bus.Event_types.Event.payload -> Data_source.record option

(** True for the payloads {!of_payload} translates. Used to build a bus filter so the subscription
    handler is not even invoked for the rest. *)
val is_market_payload : Algostream_infrastructure_event_bus.Event_types.Event.payload -> bool
