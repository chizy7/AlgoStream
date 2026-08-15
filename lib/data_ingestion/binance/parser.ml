module Event_types = Algostream_infrastructure_event_bus.Event_types
module Symbol_intern = Algostream_data_ingestion.Symbol_intern
module Clock = Algostream_common_utils.Time_utils.Clock

let buy_string = "buy"

let sell_string = "sell"

(* Subscribe to bookTicker + trade per symbol on a single /ws connection. *)
let build_subscribe_message ~symbols =
  let params =
    List.concat_map
      (fun s ->
        let lower = String.lowercase_ascii s in
          [ Printf.sprintf "%s@bookTicker" lower; Printf.sprintf "%s@trade" lower ])
      symbols in
  let arr = `List (List.map (fun s -> `String s) params) in
  let msg = `Assoc [ ("method", `String "SUBSCRIBE"); ("params", arr); ("id", `Int 1) ] in
    Yojson.Safe.to_string msg


(* Yojson helpers — slow path but correct. Hot-path optimization is a documented follow-up. *)
let assoc_string obj key default =
  match List.assoc_opt key obj with Some (`String s) -> s | _ -> default


let assoc_string_float obj key default =
  match List.assoc_opt key obj with
  | Some (`String s) -> (try float_of_string s with _ -> default)
  | Some (`Float f) -> f
  | Some (`Int n) -> float_of_int n
  | _ -> default


let assoc_int obj key default =
  match List.assoc_opt key obj with
  | Some (`Int n) -> n
  | Some (`Intlit s) -> (try int_of_string s with _ -> default)
  | _ -> default


let assoc_int64 obj key default =
  match List.assoc_opt key obj with
  | Some (`Int n) -> Int64.of_int n
  | Some (`Intlit s) -> (try Int64.of_string s with _ -> default)
  | _ -> default


let parse_book_ticker ~symbol_intern obj : Event_types.Event.payload option =
  let symbol_raw = assoc_string obj "s" "" in
    if symbol_raw = "" then None
    else
      let symbol = Symbol_intern.intern symbol_intern symbol_raw in
      let bid = assoc_string_float obj "b" 0.0 in
      let ask = assoc_string_float obj "a" 0.0 in
      let bid_qty = assoc_string_float obj "B" 0.0 in
      let ask_qty = assoc_string_float obj "A" 0.0 in
      let mid = if bid > 0.0 && ask > 0.0 then (bid +. ask) /. 2.0 else 0.0 in
      let volume = bid_qty +. ask_qty in
      (* Binance bookTicker has no timestamp; use ingest time. *)
      let ts = Clock.now_monotonic_ns () in
        Some
          (Event_types.Event.Market_tick
             { symbol; timestamp_ns = ts; price = mid; volume; bid; ask })


let parse_trade ~symbol_intern obj : Event_types.Event.payload option =
  let symbol_raw = assoc_string obj "s" "" in
    if symbol_raw = "" then None
    else
      let symbol = Symbol_intern.intern symbol_intern symbol_raw in
      (* "t" is Binance's per-symbol trade id: dense, and dense over exactly the messages this
         stream delivers, which is what makes it usable for gap detection. It used to be carried
         only as a display string while [sequence] got "T", the trade *timestamp in milliseconds* —
         so Data_quality compared consecutive millisecond values and reported the elapsed time
         between trades as "dropped". Two trades half a second apart counted as 499 lost
         messages. *)
      let trade_id_int = assoc_int obj "t" 0 in
      let trade_id = string_of_int trade_id_int in
      let price = assoc_string_float obj "p" 0.0 in
      let size = assoc_string_float obj "q" 0.0 in
      let trade_time_ms = assoc_int64 obj "T" 0L in
      let timestamp_ns = Int64.mul trade_time_ms 1_000_000L in
      (* Binance "m": true means buyer is maker → trade was a SELL on the tape (taker hits the
         bid). *)
      let is_buyer_maker = match List.assoc_opt "m" obj with Some (`Bool b) -> b | _ -> false in
      let side = if is_buyer_maker then sell_string else buy_string in
        Some
          (Event_types.Event.Trade_print
             {
               trade_id;
               symbol;
               price;
               size;
               side;
               timestamp_ns;
               sequence = Int64.of_int trade_id_int;
             })


let parse_combined_or_inner ~symbol_intern (json : Yojson.Safe.t) : Event_types.Event.payload list =
  let inner =
    match json with
    | `Assoc obj when List.mem_assoc "stream" obj && List.mem_assoc "data" obj ->
      (match List.assoc "data" obj with `Assoc o -> Some o | _ -> None)
    | `Assoc obj -> Some obj
    | _ -> None in
    match inner with
    | None -> []
    | Some obj ->
      let event_field = assoc_string obj "e" "" in
        if event_field = "trade" then
          match parse_trade ~symbol_intern obj with Some p -> [ p ] | None -> []
        else if event_field = "" && List.mem_assoc "u" obj && List.mem_assoc "s" obj then
          match parse_book_ticker ~symbol_intern obj with Some p -> [ p ] | None -> []
        else
          (* control message: subscribe ack, error, or other event types we don't subscribe to *)
          []


let parse_frame ~symbol_intern body =
  match Yojson.Safe.from_string body with
  | json -> parse_combined_or_inner ~symbol_intern json
  | exception Yojson.Json_error _ -> []
