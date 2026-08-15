(** Normalized tick record bridging bus payloads (Market_tick / Trade_print) into the analytics
    pipeline. Field set is intentionally narrower than the bus payloads: only what the analytics
    layer actually uses, so the SPSC handoff is small and predictable. *)

type kind =
  | Market
  | Trade

type t = {
  symbol : string;
  timestamp_ns : int64; (* exchange-reported event time *)
  price : float; (* mid for Market_tick, trade price for Trade_print *)
  size : float; (* volume on Market_tick, trade size on Trade_print *)
  bid : float; (* 0.0 if Trade_print *)
  ask : float; (* 0.0 if Trade_print *)
  kind : kind;
}

(** Convert from the bus payload. Returns None for payload variants we don't process. *)
val of_event_payload : Algostream_infrastructure_event_bus.Event_types.Event.payload -> t option
