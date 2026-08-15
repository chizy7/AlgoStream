module Data_source = Algostream_backtest.Data_source
module Event = Algostream_infrastructure_event_bus.Event_types.Event
module Side = Algostream_strategy.Side

let of_payload (p : Event.payload) : Data_source.record option =
  match p with
  | Event.Market_tick { symbol; timestamp_ns; price; volume; bid; ask } ->
    (* The bus carries bid/ask as plain floats; the record wants options, and a non-positive quote
       means "not known" rather than "the market is at zero". *)
    let opt v = if v > 0.0 then Some v else None in
      Some
        (Data_source.Tick
           { symbol; ts_ns = timestamp_ns; price; volume; bid = opt bid; ask = opt ask })
  | Event.Trade_print { trade_id = _; symbol; price; size; side; timestamp_ns; sequence = _ } ->
    let aggressor =
      match String.lowercase_ascii side with
      | "buy" | "b" | "bid" -> Some Side.Buy
      | "sell" | "s" | "ask" -> Some Side.Sell
      | _ -> None in
      Some (Data_source.Trade_print { symbol; ts_ns = timestamp_ns; price; size; aggressor })
  | Event.Heartbeat | Event.Shutdown | Event.Order_request _ | Event.Order_response _
  | Event.Trade_execution _ | Event.Risk_alert _ | Event.Strategy_signal _ | Event.Raw _
  | Event.Data_gap _ ->
    None


let is_market_payload (p : Event.payload) =
  match p with Event.Market_tick _ | Event.Trade_print _ -> true | _ -> false
