open Base
module Timestamp = Algostream_domain_common.Timestamp

type position_side =
  | Long
  | Short
  | Flat
[@@deriving sexp, compare, hash]

type position = {
  symbol : string;
  quantity : float;
  average_price : float;
  last_price : float;
  unrealized_pnl : float;
  realized_pnl : float;
  total_cost : float;
  commission_paid : float;
  opened_at : Timestamp.t;
  updated_at : Timestamp.t;
  strategy_id : string option;
}
[@@deriving sexp, compare]

(* Event-time hook. Layers that must stay replay-deterministic — the backtest engine above all —
   pass [~ts] derived from the event stream ([Timestamp.of_ns tick.timestamp_ns]); live callers omit
   it and get the wall clock, exactly as before. [?ts] leads the argument list in every mutator here
   so it stays erasable without a trailing [unit]. *)
let stamp = function Some t -> t | None -> Timestamp.now ()

let create_position ?ts ~symbol ?strategy_id () =
  let now = stamp ts in
    {
      symbol;
      quantity = 0.0;
      average_price = 0.0;
      last_price = 0.0;
      unrealized_pnl = 0.0;
      realized_pnl = 0.0;
      total_cost = 0.0;
      commission_paid = 0.0;
      opened_at = now;
      updated_at = now;
      strategy_id;
    }


let position_side position =
  if Float.(position.quantity = 0.0) then Flat
  else if Float.(position.quantity > 0.0) then Long
  else Short


let is_flat position = Float.(position.quantity = 0.0)

let is_long position = Float.(position.quantity > 0.0)

let is_short position = Float.(position.quantity < 0.0)

let market_value position = position.quantity *. position.last_price

let cost_basis position = Float.abs position.quantity *. position.average_price

let update_last_price ?ts position ~new_price =
  let new_unrealized_pnl =
    if Float.(position.quantity = 0.0) then 0.0
    else (new_price -. position.average_price) *. position.quantity in
    {
      position with
      last_price = new_price;
      unrealized_pnl = new_unrealized_pnl;
      updated_at = stamp ts;
    }


let add_trade ?ts position ~trade_quantity ~trade_price ~commission =
  let now = stamp ts in
  let new_quantity = position.quantity +. trade_quantity in
  let new_commission = position.commission_paid +. commission in

  if Float.(position.quantity = 0.0) then
    (* Opening position *)
    {
      position with
      quantity = new_quantity;
      average_price = trade_price;
      total_cost = (Float.abs trade_quantity *. trade_price) +. commission;
      commission_paid = new_commission;
      opened_at = now;
      updated_at = now;
    }
  else
    let old_side = position_side position in
    let trade_side = if Float.(trade_quantity > 0.0) then Long else Short in

    if Float.(new_quantity = 0.0) then
      (* Closing position completely *)
      let pnl =
        match old_side with
        | Long -> (trade_price -. position.average_price) *. Float.abs trade_quantity
        | Short -> (position.average_price -. trade_price) *. Float.abs trade_quantity
        | Flat -> 0.0 in
        {
          position with
          quantity = 0.0;
          average_price = 0.0;
          realized_pnl = position.realized_pnl +. pnl -. commission;
          commission_paid = new_commission;
          updated_at = now;
        }
    else if
      (Poly.equal old_side Long && Poly.equal trade_side Long)
      || (Poly.equal old_side Short && Poly.equal trade_side Short)
    then
      (* Adding to position *)
      let total_cost = position.total_cost +. (Float.abs trade_quantity *. trade_price) in
      let new_average_price = total_cost /. Float.abs new_quantity in
        {
          position with
          quantity = new_quantity;
          average_price = new_average_price;
          total_cost = total_cost +. commission;
          commission_paid = new_commission;
          updated_at = now;
        }
    else
      (* Reducing position (opposite side) *)
      let closing_quantity = Float.min (Float.abs position.quantity) (Float.abs trade_quantity) in
      let pnl =
        match old_side with
        | Long -> (trade_price -. position.average_price) *. closing_quantity
        | Short -> (position.average_price -. trade_price) *. closing_quantity
        | Flat -> 0.0 in
      let remaining_trade_quantity =
        trade_quantity
        +. if Poly.equal old_side Long then position.quantity else -.position.quantity in

      if Float.(remaining_trade_quantity = 0.0) then
        {
          position with
          quantity = 0.0;
          average_price = 0.0;
          realized_pnl = position.realized_pnl +. pnl -. commission;
          commission_paid = new_commission;
          updated_at = now;
        }
      else
        {
          position with
          quantity = remaining_trade_quantity;
          average_price = trade_price;
          total_cost = (Float.abs remaining_trade_quantity *. trade_price) +. commission;
          realized_pnl = position.realized_pnl +. pnl;
          commission_paid = new_commission;
          updated_at = now;
        }


let total_pnl position = position.realized_pnl +. position.unrealized_pnl

let pnl_percentage position =
  if Float.(position.total_cost = 0.0) then 0.0
  else total_pnl position /. position.total_cost *. 100.0


let exposure position = Float.abs (market_value position)

let leverage position ~account_value =
  if Float.(account_value = 0.0) then 0.0 else exposure position /. account_value


module Position_analytics = struct
  type analytics = {
    holding_period : float; (* in seconds *)
    max_unrealized_pnl : float;
    min_unrealized_pnl : float;
    max_position_size : float;
    turnover : float;
  }
  [@@deriving sexp]

  (* [?ts] is "now" for the purpose of the holding-period calculation. Backtests pass the current
     event time so [holding_period] is a function of the replayed stream, not of when the report
     happened to be generated. *)
  let calculate_analytics ?ts position ~price_history =
    let now = stamp ts in
    let holding_period = Timestamp.diff now position.opened_at in

    let max_unrealized = ref position.unrealized_pnl in
    let min_unrealized = ref position.unrealized_pnl in
    let max_size = ref (Float.abs position.quantity) in

    List.iter price_history ~f:(fun price ->
      let temp_unrealized = (price -. position.average_price) *. position.quantity in
        if Float.(temp_unrealized > !max_unrealized) then max_unrealized := temp_unrealized ;
        if Float.(temp_unrealized < !min_unrealized) then min_unrealized := temp_unrealized) ;

    {
      holding_period;
      max_unrealized_pnl = !max_unrealized;
      min_unrealized_pnl = !min_unrealized;
      max_position_size = !max_size;
      turnover = Float.abs position.quantity *. position.average_price;
    }


  type risk_metrics = {
    position_volatility : float;
    value_at_risk_95 : float;
    expected_shortfall_95 : float;
    leverage_ratio : float;
  }
  [@@deriving sexp]

  let risk_metrics position ~volatility =
    let position_volatility = volatility *. Float.abs position.quantity *. position.last_price in
    let value_at_risk_95 = position_volatility *. 1.645 in
    (* 95% VaR assuming normal distribution *)
    let expected_shortfall_95 = position_volatility *. 2.06 in
      (* 95% ES *)
      {
        position_volatility;
        value_at_risk_95;
        expected_shortfall_95;
        leverage_ratio = Float.abs position.quantity *. position.last_price /. cost_basis position;
      }
end
