(** Coinbase Exchange WebSocket frame parser (the public, unauthenticated feed at
    [wss://ws-feed.exchange.coinbase.com]).

    Subscribes to [ticker] (BBO + last trade) and [matches] (every fill on the tape). The newer
    Advanced Trade WS endpoint requires JWT auth even for public market data, so we use the older
    Exchange WS which remains public.

    Frame layout reference (Exchange WS):
    {v
      ticker:  { "type":"ticker", "sequence":..., "product_id":"BTC-USD", "best_bid":"...",
                 "best_ask":"...", "best_bid_size":"...", "best_ask_size":"...", "price":"...",
                 "last_size":"...", "time":"<ISO-8601>" }
      match:   { "type":"match", "trade_id":..., "sequence":..., "product_id":"BTC-USD",
                 "price":"...", "size":"...", "side":"buy|sell", "time":"<ISO-8601>" }
    v}

    Numbers are JSON strings on Coinbase — we [float_of_string] them. Time is ISO-8601 with
    microsecond precision. We currently use ingest time (parsing ISO-8601 needs ptime which is not
    yet a dep; flagged as a follow-up). *)

val build_subscribe_message : symbols:string list -> string

val parse_frame :
  symbol_intern:Algostream_data_ingestion.Symbol_intern.t ->
  string ->
  Algostream_infrastructure_event_bus.Event_types.Event.payload list
