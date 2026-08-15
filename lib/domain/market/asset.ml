open Base

type asset_class =
  | Equity
  | Forex
  | Crypto
  | Fixed_income
  | Commodity
  | Derivative
[@@deriving sexp, compare, hash]

type asset = {
  symbol : string;
  name : string;
  asset_class : asset_class;
  exchange : string;
  base_currency : string option;
  quote_currency : string option;
  min_trade_size : float;
  tick_size : float;
  multiplier : float;
  active : bool;
}
[@@deriving sexp, compare, hash]

let create_equity ~symbol ~name ~exchange ~tick_size =
  {
    symbol;
    name;
    asset_class = Equity;
    exchange;
    base_currency = None;
    quote_currency = Some "USD";
    min_trade_size = 1.0;
    tick_size;
    multiplier = 1.0;
    active = true;
  }


let create_crypto ~symbol ~name ~exchange ~base_currency ~quote_currency ~tick_size =
  {
    symbol;
    name;
    asset_class = Crypto;
    exchange;
    base_currency = Some base_currency;
    quote_currency = Some quote_currency;
    min_trade_size = 0.000001;
    tick_size;
    multiplier = 1.0;
    active = true;
  }


let create_forex ~symbol ~name ~base_currency ~quote_currency =
  {
    symbol;
    name;
    asset_class = Forex;
    exchange = "FX";
    base_currency = Some base_currency;
    quote_currency = Some quote_currency;
    min_trade_size = 0.01;
    tick_size = 0.00001;
    multiplier = 100000.0;
    active = true;
  }


let is_tradeable asset = asset.active

let get_full_symbol asset =
  match (asset.base_currency, asset.quote_currency) with
  | Some base, Some quote -> Printf.sprintf "%s/%s" base quote
  | _ -> asset.symbol
