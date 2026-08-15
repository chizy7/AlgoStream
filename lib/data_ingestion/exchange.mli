(** Abstract interface that each concrete exchange (Binance, Coinbase, …) implements.

    The supervisor instantiates one of these per configured exchange and drives the WebSocket loop
    against it. *)

module type S = sig
  val name : string

  (** Build the subscribe message sent right after WebSocket upgrade. *)
  val build_subscribe_message : symbols:string list -> string

  (** Decode a raw text frame payload into zero or more event-bus payloads.

      [symbol_intern] is a per-Domain interner so symbol strings reuse storage across calls. Returns
      an empty list for unrecognised / control frames (subscribe ack, pong, etc.). *)
  val parse_frame :
    symbol_intern:Symbol_intern.t ->
    string ->
    Algostream_infrastructure_event_bus.Event_types.Event.payload list
end
