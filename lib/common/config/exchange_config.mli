(** Per-exchange ingestion configuration.

    Pure data + a JSON loader. Read from a config file at startup or built programmatically. *)

type retry_policy = {
  base_backoff_ms : int;
  max_backoff_ms : int;
  jitter_pct : float; (* 0.0 - 1.0 *)
  circuit_breaker_threshold : int; (* consecutive failures before circuit opens *)
  circuit_open_ms : int;
  connect_timeout_ms : int;
  read_timeout_ms : int;
}

type t = {
  name : string; (* "binance" | "coinbase" *)
  endpoints : string list; (* ordered failover list, first = primary *)
  symbols : string list; (* normalized exchange symbols, e.g. ["BTCUSDT"] *)
  retry : retry_policy;
  rate_limit_per_sec : int; (* outbound control-frame budget *)
  pong_reserve_per_sec : int; (* tokens reserved exclusively for pong replies *)
}

val default_retry : retry_policy

val binance_default : symbols:string list -> t

val coinbase_default : symbols:string list -> t

(** Parse a single-exchange JSON object. *)
val of_yojson : Yojson.Safe.t -> (t, string) result

(** Load a JSON config file. Top-level shape is either a single exchange object or an array of them.
*)
val load_file : string -> (t list, string) result
