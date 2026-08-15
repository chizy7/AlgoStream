(** Binance Spot WebSocket frame parser.

    Connects to [wss://stream.binance.com/ws] and subscribes via JSON SUBSCRIBE for
    [<symbol>@bookTicker] (top-of-book) and [<symbol>@trade] (tape prints) per configured symbol.

    Frame layout reference:
    {v
      bookTicker:  { "u":update_id, "s":symbol, "b":bid, "B":bid_qty,
                     "a":ask, "A":ask_qty }   (NO timestamp)
      trade:       { "e":"trade", "E":event_ts_ms, "s":symbol, "t":trade_id,
                     "p":price, "q":qty, "T":trade_ts_ms, "m":is_maker_buy, ... }
    v}

    Numbers are JSON strings on Binance — we [float_of_string] them. *)

val build_subscribe_message : symbols:string list -> string

val parse_frame :
  symbol_intern:Algostream_data_ingestion.Symbol_intern.t ->
  string ->
  Algostream_infrastructure_event_bus.Event_types.Event.payload list
