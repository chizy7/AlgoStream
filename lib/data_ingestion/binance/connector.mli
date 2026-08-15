(** Binance Spot WebSocket connector.

    Implements the {!Algostream_data_ingestion.Exchange.S} signature so the supervisor can drive the
    connection loop generically. *)

include Algostream_data_ingestion.Exchange.S
