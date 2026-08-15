module Venue = Algostream_order_management.Venue
module Portfolio = Algostream_domain_portfolio.Portfolio
module Trade = Algostream_domain_trades.Trade

type config = {
  venue : Venue.t;
  extra_fee_bps : float;
  min_commission : float;
  borrow_bps_per_day : float;
  funding_bps_per_day : float;
  initial_monthly_volume : float;
}

type t = {
  cfg : config;
  mutable volume : float;
  mutable commission_paid : float;
  mutable financing_paid : float;
}

let default_config venue =
  {
    venue;
    extra_fee_bps = 0.0;
    min_commission = 0.0;
    (* Crypto spot margin borrow is typically tens of bps a day; zero by default so a spot backtest
       is not silently charged for leverage it does not use. *)
    borrow_bps_per_day = 0.0;
    funding_bps_per_day = 0.0;
    initial_monthly_volume = 0.0;
  }


let create cfg =
  { cfg; volume = cfg.initial_monthly_volume; commission_paid = 0.0; financing_paid = 0.0 }


let current_fee_bps t ~taker =
  Venue.effective_fee_bps t.cfg.venue ~taker ~monthly_volume:t.volume +. t.cfg.extra_fee_bps


let commission t ~notional ~liquidity =
  let taker = match liquidity with Trade.Taker -> true | Trade.Maker | Trade.Self_trade -> false in
  let bps = current_fee_bps t ~taker in
  let fee = Float.abs notional *. bps /. 10_000.0 in
  let fee = Float.max fee t.cfg.min_commission in
    t.commission_paid <- t.commission_paid +. fee ;
    fee


(* Called after commission so a fill is priced at the tier it executed under, not the one it pushes
   the account into. *)
let observe_fill t ~notional = t.volume <- t.volume +. Float.abs notional

let ns_per_day = 86_400.0 *. 1e9

let accrue_financing t ~portfolio ~prev_ts_ns ~now_ns =
  let dt = Int64.sub now_ns prev_ts_ns in
    if Int64.compare dt 0L <= 0 then 0.0
    else if t.cfg.borrow_bps_per_day <= 0.0 && t.cfg.funding_bps_per_day <= 0.0 then 0.0
    else
      let days = Int64.to_float dt /. ns_per_day in
      let short = Float.abs (Portfolio.short_exposure portfolio) in
      let gross = Portfolio.gross_exposure portfolio in
      let borrow = short *. t.cfg.borrow_bps_per_day /. 10_000.0 *. days in
      let funding = gross *. t.cfg.funding_bps_per_day /. 10_000.0 *. days in
      let total = borrow +. funding in
        t.financing_paid <- t.financing_paid +. total ;
        total


let monthly_volume t = t.volume

let total_commission t = t.commission_paid

let total_financing t = t.financing_paid
