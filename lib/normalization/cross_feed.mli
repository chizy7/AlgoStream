(** Cross-feed price-basis tracker.

    For two feeds A and B reporting the *same canonical symbol* (e.g. Binance BTCUSDT vs Coinbase
    BTC-USDT), the basis is [(price_a - price_b) / mid]. Rolling mean / variance of the basis turns
    into a Z-score; large |Z| flags an anomaly without the false-positives that fixed-threshold
    checks produce.

    NOTE: never pair across non-equivalent quotes — Binance "BTCUSDT" against Coinbase "BTC-USD" is
    a USDT-vs-USD basis, not a "Binance vs Coinbase" inconsistency. Construct a separate [t] per
    (canonical_pair, feed_pair) accordingly. *)

type t

val create : canonical:Symbol.t -> feed_a:string -> feed_b:string -> ?window:int -> unit -> t

val update : t -> ts_ns:int64 -> price_a:float -> price_b:float -> unit

type stats = {
  mean_basis : float;
  std_basis : float;
  current_basis : float;
  current_z : float;
  n : int;
  last_ts_ns : int64;
}

val stats : t -> stats

val canonical : t -> Symbol.t

val feeds : t -> string * string
