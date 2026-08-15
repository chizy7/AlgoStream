type retry_policy = {
  base_backoff_ms : int;
  max_backoff_ms : int;
  jitter_pct : float;
  circuit_breaker_threshold : int;
  circuit_open_ms : int;
  connect_timeout_ms : int;
  read_timeout_ms : int;
}

type t = {
  name : string;
  endpoints : string list;
  symbols : string list;
  retry : retry_policy;
  rate_limit_per_sec : int;
  pong_reserve_per_sec : int;
}

let default_retry =
  {
    base_backoff_ms = 1_000;
    max_backoff_ms = 30_000;
    jitter_pct = 0.25;
    circuit_breaker_threshold = 5;
    circuit_open_ms = 60_000;
    connect_timeout_ms = 5_000;
    read_timeout_ms = 30_000;
  }


let binance_default ~symbols =
  {
    name = "binance";
    endpoints =
      [
        "wss://stream.binance.com:9443";
        "wss://stream.binance.com:443";
        "wss://stream-fallback.binance.com:443";
      ];
    symbols;
    retry = default_retry;
    rate_limit_per_sec = 5;
    pong_reserve_per_sec = 1;
  }


(* The newer Advanced Trade WS at wss://advanced-trade-ws.coinbase.com requires JWT auth even for
   public market data. We use the older Exchange WS feed which remains unauthenticated. *)
let coinbase_default ~symbols =
  {
    name = "coinbase";
    endpoints = [ "wss://ws-feed.exchange.coinbase.com" ];
    symbols;
    retry = default_retry;
    rate_limit_per_sec = 5;
    pong_reserve_per_sec = 1;
  }


let int_field obj key default =
  match List.assoc_opt key obj with Some (`Int n) -> n | _ -> default


let float_field obj key default =
  match List.assoc_opt key obj with
  | Some (`Float x) -> x
  | Some (`Int n) -> float_of_int n
  | _ -> default


let string_list_field obj key =
  match List.assoc_opt key obj with
  | Some (`List xs) -> List.filter_map (function `String s -> Some s | _ -> None) xs
  | _ -> []


let retry_of_yojson_obj obj =
  let r = default_retry in
    {
      base_backoff_ms = int_field obj "base_backoff_ms" r.base_backoff_ms;
      max_backoff_ms = int_field obj "max_backoff_ms" r.max_backoff_ms;
      jitter_pct = float_field obj "jitter_pct" r.jitter_pct;
      circuit_breaker_threshold =
        int_field obj "circuit_breaker_threshold" r.circuit_breaker_threshold;
      circuit_open_ms = int_field obj "circuit_open_ms" r.circuit_open_ms;
      connect_timeout_ms = int_field obj "connect_timeout_ms" r.connect_timeout_ms;
      read_timeout_ms = int_field obj "read_timeout_ms" r.read_timeout_ms;
    }


let of_yojson = function
  | `Assoc obj ->
    let name = match List.assoc_opt "name" obj with Some (`String s) -> s | _ -> "" in
      if name = "" then Error "exchange_config: missing \"name\""
      else
        let endpoints = string_list_field obj "endpoints" in
        let symbols = string_list_field obj "symbols" in
        let retry =
          match List.assoc_opt "retry" obj with
          | Some (`Assoc r_obj) -> retry_of_yojson_obj r_obj
          | _ -> default_retry in
        let rate_limit_per_sec = int_field obj "rate_limit_per_sec" 5 in
        let pong_reserve_per_sec = int_field obj "pong_reserve_per_sec" 1 in
          Ok { name; endpoints; symbols; retry; rate_limit_per_sec; pong_reserve_per_sec }
  | _ -> Error "exchange_config: expected a JSON object"


let load_file path =
  match Yojson.Safe.from_file path with
  | exception Yojson.Json_error msg -> Error ("exchange_config: " ^ msg)
  | exception Sys_error msg -> Error ("exchange_config: " ^ msg)
  | `List items ->
    let parsed = List.map of_yojson items in
    let rec collect acc = function
      | [] -> Ok (List.rev acc)
      | Ok x :: rest -> collect (x :: acc) rest
      | Error e :: _ -> Error e in
      collect [] parsed
  | other -> (match of_yojson other with Ok x -> Ok [ x ] | Error e -> Error e)
