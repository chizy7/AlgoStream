module ET = Algostream_infrastructure_event_bus.Event_types

type kind =
  | Market
  | Trade

type t = {
  symbol : string;
  timestamp_ns : int64;
  price : float;
  size : float;
  bid : float;
  ask : float;
  kind : kind;
}

let of_event_payload : ET.Event.payload -> t option = function
  | ET.Event.Market_tick { symbol; timestamp_ns; price; volume; bid; ask } ->
    Some { symbol; timestamp_ns; price; size = volume; bid; ask; kind = Market }
  | ET.Event.Trade_print { symbol; timestamp_ns; price; size; _ } ->
    Some { symbol; timestamp_ns; price; size; bid = 0.0; ask = 0.0; kind = Trade }
  | _ -> None
