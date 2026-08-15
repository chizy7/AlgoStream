module Event_types = Algostream_infrastructure_event_bus.Event_types
module Symbol_intern = Algostream_data_ingestion.Symbol_intern
module Clock = Algostream_common_utils.Time_utils.Clock

let buy_string = "buy"

let sell_string = "sell"

(* Coinbase Exchange uses one subscribe with multiple channels at once. *)
let build_subscribe_message ~symbols =
  let products = `List (List.map (fun s -> `String s) symbols) in
  let channels = `List [ `String "ticker"; `String "matches" ] in
  let msg =
    `Assoc [ ("type", `String "subscribe"); ("product_ids", products); ("channels", channels) ]
  in
    Yojson.Safe.to_string msg


let assoc_string obj key default =
  match List.assoc_opt key obj with Some (`String s) -> s | _ -> default


let assoc_string_float obj key default =
  match List.assoc_opt key obj with
  | Some (`String s) -> (try float_of_string s with _ -> default)
  | Some (`Float f) -> f
  | Some (`Int n) -> float_of_int n
  | _ -> default


let assoc_int64 obj key default =
  match List.assoc_opt key obj with
  | Some (`Int n) -> Int64.of_int n
  | Some (`Intlit s) -> (try Int64.of_string s with _ -> default)
  | _ -> default


let parse_ticker ~symbol_intern obj : Event_types.Event.payload option =
  let symbol_raw = assoc_string obj "product_id" "" in
    if symbol_raw = "" then None
    else
      let symbol = Symbol_intern.intern symbol_intern symbol_raw in
      let bid = assoc_string_float obj "best_bid" 0.0 in
      let ask = assoc_string_float obj "best_ask" 0.0 in
      let bid_size = assoc_string_float obj "best_bid_size" 0.0 in
      let ask_size = assoc_string_float obj "best_ask_size" 0.0 in
      let price = assoc_string_float obj "price" 0.0 in
      let volume = bid_size +. ask_size in
      let timestamp_ns = Clock.now_monotonic_ns () in
        Some (Event_types.Event.Market_tick { symbol; timestamp_ns; price; volume; bid; ask })


let parse_match ~symbol_intern obj : Event_types.Event.payload option =
  let symbol_raw = assoc_string obj "product_id" "" in
    if symbol_raw = "" then None
    else
      let symbol = Symbol_intern.intern symbol_intern symbol_raw in
      let trade_id_int = assoc_int64 obj "trade_id" 0L in
      let trade_id = Int64.to_string trade_id_int in
      (* [trade_id], not the message's "sequence" field.

         Coinbase's [sequence] counts every message on the product's *full* channel — order opens,
         changes, cancels — while this connector subscribes only to [matches]. Consecutive matches
         therefore carry wildly non-contiguous sequence numbers, and treating the difference as lost
         messages made the gap detector report nonsense: over one hour of BTC-USD it claimed
         2,096,488 dropped against 25,706 observed. [trade_id] increments by one per trade on the
         product, so it is dense over exactly the messages we receive. *)
      let sequence = trade_id_int in
      let price = assoc_string_float obj "price" 0.0 in
      let size = assoc_string_float obj "size" 0.0 in
      let raw_side = assoc_string obj "side" "" in
      let side = if raw_side = "buy" then buy_string else sell_string in
      let timestamp_ns = Clock.now_monotonic_ns () in
        Some
          (Event_types.Event.Trade_print
             { trade_id; symbol; price; size; side; timestamp_ns; sequence })


let parse_frame ~symbol_intern body =
  match Yojson.Safe.from_string body with
  | exception Yojson.Json_error _ -> []
  | `Assoc obj ->
    let typ = assoc_string obj "type" "" in
      if typ = "ticker" then
        match parse_ticker ~symbol_intern obj with Some p -> [ p ] | None -> []
      else if typ = "match" || typ = "last_match" then
        match parse_match ~symbol_intern obj with Some p -> [ p ] | None -> []
      else
        (* subscribe ack, error, heartbeat — handled as control *)
        []
  | _ -> []
