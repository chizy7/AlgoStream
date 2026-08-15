module type S = sig
  val name : string

  val build_subscribe_message : symbols:string list -> string

  val parse_frame :
    symbol_intern:Symbol_intern.t ->
    string ->
    Algostream_infrastructure_event_bus.Event_types.Event.payload list
end
