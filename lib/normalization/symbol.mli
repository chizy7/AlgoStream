(** Canonical cross-exchange symbol.

    Resolves exchange-native strings ("BTCUSDT" on Binance, "BTC-USD" on Coinbase) to a common
    shape. Note that USDT and USD are intentionally treated as DIFFERENT quote currencies — they are
    not the same instrument and the cross-feed basis between them is a real signal, not a
    normalization error. *)

type asset_class =
  | Crypto
  | Equity
  | Forex

type t = {
  base : string;
  quote : string;
  asset_class : asset_class;
}

val equal : t -> t -> bool

(** "BTC/USDT", "ETH/USD", "AAPL/USD" — strategy-facing form. *)
val to_canonical : t -> string

(** Static lookup against a per-exchange table (Binance and Coinbase ship by default). Returns
    [None] for unknown exchange or unparseable raw string. *)
val parse : exchange:string -> raw:string -> t option

(** Test hook: register a (exchange, raw) → canonical mapping at runtime. The table is shared
    process-wide. *)
val register : exchange:string -> raw:string -> t -> unit

(** Inverse: given a canonical symbol and a target exchange, produce the exchange-native string (or
    None if no mapping exists). *)
val to_exchange : t -> exchange:string -> string option
