type asset_class =
  | Crypto
  | Equity
  | Forex

type t = {
  base : string;
  quote : string;
  asset_class : asset_class;
}

let equal a b =
  String.equal a.base b.base && String.equal a.quote b.quote && a.asset_class = b.asset_class


let to_canonical t = Printf.sprintf "%s/%s" t.base t.quote

(* Process-wide mapping table. Two views: (exchange, raw) -> canonical, and (canonical_str,
   exchange) -> raw. Shared across Domains; reads vastly outnumber writes (writes only at startup or
   in tests). For v1 a single Mutex is fine; lock-free can come later. *)

let table_lock = Mutex.create ()

let by_raw : (string * string, t) Hashtbl.t = Hashtbl.create 64

let by_canonical : (string * string, string) Hashtbl.t = Hashtbl.create 64

(* canonical_str * exchange -> raw *)

let do_register ~exchange ~raw canonical =
  Mutex.lock table_lock ;
  Hashtbl.replace by_raw (exchange, raw) canonical ;
  Hashtbl.replace by_canonical (to_canonical canonical, exchange) raw ;
  Mutex.unlock table_lock


let register = do_register

(* ───── default seed: Binance + Coinbase majors ──────────────────── *)

let crypto base quote = { base; quote; asset_class = Crypto }

let () =
  let pairs =
    [
      ("binance", "BTCUSDT", crypto "BTC" "USDT");
      ("binance", "ETHUSDT", crypto "ETH" "USDT");
      ("binance", "SOLUSDT", crypto "SOL" "USDT");
      ("binance", "BNBUSDT", crypto "BNB" "USDT");
      ("binance", "BTCUSDC", crypto "BTC" "USDC");
      ("binance", "ETHUSDC", crypto "ETH" "USDC");
      ("coinbase", "BTC-USD", crypto "BTC" "USD");
      ("coinbase", "ETH-USD", crypto "ETH" "USD");
      ("coinbase", "SOL-USD", crypto "SOL" "USD");
      ("coinbase", "ETH-BTC", crypto "ETH" "BTC");
    ] in
    List.iter (fun (ex, raw, can) -> do_register ~exchange:ex ~raw can) pairs


(* ───── lookups (read-only paths) ───────────────────────────────── *)

let parse ~exchange ~raw =
  Mutex.lock table_lock ;
  let r = Hashtbl.find_opt by_raw (exchange, raw) in
    Mutex.unlock table_lock ;
    r


let to_exchange t ~exchange =
  Mutex.lock table_lock ;
  let r = Hashtbl.find_opt by_canonical (to_canonical t, exchange) in
    Mutex.unlock table_lock ;
    r
