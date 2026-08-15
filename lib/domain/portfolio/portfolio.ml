open Base
module Timestamp = Algostream_domain_common.Timestamp
module Position = Position

type portfolio = {
  account_id : string;
  positions : (string, Position.position) Map.Poly.t;
  cash_balance : float;
  initial_capital : float;
  total_commission_paid : float;
  created_at : Timestamp.t;
  updated_at : Timestamp.t;
  strategy_allocations : (string, float) Map.Poly.t;
}
[@@deriving sexp]

(* Event-time hook — see the note in [Position]. Backtests thread the replayed event time through
   [~ts]; live callers omit it and keep the wall clock. *)
let stamp = function Some t -> t | None -> Timestamp.now ()

(* NOTE: this is the one mutator whose arity changed — it has no positional parameter for [?ts] to
   precede, so an erasable optional argument requires the trailing [unit]. Six call sites updated;
   recorded in the CHANGELOG as a breaking change. *)
let create_portfolio ?ts ~account_id ~initial_capital () =
  let now = stamp ts in
    {
      account_id;
      positions = Map.Poly.empty;
      cash_balance = initial_capital;
      initial_capital;
      total_commission_paid = 0.0;
      created_at = now;
      updated_at = now;
      strategy_allocations = Map.Poly.empty;
    }


let get_position portfolio ~symbol = Map.Poly.find portfolio.positions symbol

let has_position portfolio ~symbol =
  match get_position portfolio ~symbol with
  | Some position -> not (Position.is_flat position)
  | None -> false


let add_trade ?ts portfolio ~symbol ~trade_quantity ~trade_price ~commission ?strategy_id () =
  let now = stamp ts in
  let existing_position =
    match get_position portfolio ~symbol with
    | Some pos -> pos
    | None -> Position.create_position ~ts:now ~symbol ?strategy_id () in
  let updated_position =
    Position.add_trade ~ts:now existing_position ~trade_quantity ~trade_price ~commission in
  let new_cash = portfolio.cash_balance -. (trade_quantity *. trade_price) -. commission in
  let updated_positions = Map.Poly.set portfolio.positions ~key:symbol ~data:updated_position in
    {
      portfolio with
      positions = updated_positions;
      cash_balance = new_cash;
      total_commission_paid = portfolio.total_commission_paid +. commission;
      updated_at = now;
    }


let update_position_prices ?ts portfolio ~price_updates =
  let now = stamp ts in
  let updated_positions =
    Map.Poly.fold price_updates ~init:portfolio.positions ~f:(fun ~key:symbol ~data:new_price acc ->
      match Map.Poly.find acc symbol with
      | Some position ->
        let updated_position = Position.update_last_price ~ts:now position ~new_price in
          Map.Poly.set acc ~key:symbol ~data:updated_position
      | None -> acc) in
    { portfolio with positions = updated_positions; updated_at = now }


let total_market_value portfolio =
  Map.Poly.fold portfolio.positions ~init:0.0 ~f:(fun ~key:_ ~data:position acc ->
    acc +. Position.market_value position)


let net_asset_value portfolio = portfolio.cash_balance +. total_market_value portfolio

let total_unrealized_pnl portfolio =
  Map.Poly.fold portfolio.positions ~init:0.0 ~f:(fun ~key:_ ~data:position acc ->
    acc +. position.unrealized_pnl)


let total_realized_pnl portfolio =
  Map.Poly.fold portfolio.positions ~init:0.0 ~f:(fun ~key:_ ~data:position acc ->
    acc +. position.realized_pnl)


let total_pnl portfolio = total_realized_pnl portfolio +. total_unrealized_pnl portfolio

let portfolio_return portfolio =
  if Float.(portfolio.initial_capital = 0.0) then 0.0
  else total_pnl portfolio /. portfolio.initial_capital *. 100.0


let gross_exposure portfolio =
  Map.Poly.fold portfolio.positions ~init:0.0 ~f:(fun ~key:_ ~data:position acc ->
    acc +. Position.exposure position)


let net_exposure portfolio =
  Map.Poly.fold portfolio.positions ~init:0.0 ~f:(fun ~key:_ ~data:position acc ->
    acc +. Position.market_value position)


let leverage portfolio =
  let nav = net_asset_value portfolio in
    if Float.(nav = 0.0) then 0.0 else gross_exposure portfolio /. nav


let long_exposure portfolio =
  Map.Poly.fold portfolio.positions ~init:0.0 ~f:(fun ~key:_ ~data:position acc ->
    if Position.is_long position then acc +. Position.exposure position else acc)


let short_exposure portfolio =
  Map.Poly.fold portfolio.positions ~init:0.0 ~f:(fun ~key:_ ~data:position acc ->
    if Position.is_short position then acc +. Position.exposure position else acc)


let position_count portfolio =
  Map.Poly.count portfolio.positions ~f:(fun position -> not (Position.is_flat position))


let largest_position portfolio =
  Map.Poly.fold portfolio.positions ~init:None ~f:(fun ~key:symbol ~data:position acc ->
    let exposure = Position.exposure position in
      match acc with
      | None -> Some (symbol, position, exposure)
      | Some (_, _, max_exposure) when Float.(exposure > max_exposure) ->
        Some (symbol, position, exposure)
      | Some _ -> acc)


let diversification_ratio portfolio =
  let count = Float.of_int (position_count portfolio) in
    if Float.(count <= 1.0) then 0.0
    else
      let total_exposure = gross_exposure portfolio in
        if Float.(total_exposure = 0.0) then 0.0
        else
          let sum_squared_weights =
            Map.Poly.fold portfolio.positions ~init:0.0 ~f:(fun ~key:_ ~data:position acc ->
              let weight = Position.exposure position /. total_exposure in
                acc +. (weight *. weight)) in
            1.0 -. sum_squared_weights


module Risk_metrics = struct
  type risk_metrics = {
    value_at_risk_95 : float;
    expected_shortfall_95 : float;
    maximum_drawdown : float;
    volatility : float;
    sharpe_ratio : float option;
    beta : float option;
  }
  [@@deriving sexp]

  let calculate_portfolio_volatility returns =
    if List.length returns < 2 then 0.0
    else
      let mean = List.fold returns ~init:0.0 ~f:( +. ) /. Float.of_int (List.length returns) in
      let variance =
        List.fold returns ~init:0.0 ~f:(fun acc ret -> acc +. ((ret -. mean) *. (ret -. mean)))
        /. (Float.of_int (List.length returns) -. 1.0) in
        Float.sqrt variance


  let calculate_var returns ~confidence_level =
    let sorted_returns = List.sort returns ~compare:Float.compare in
    let index = Int.of_float (Float.of_int (List.length returns) *. (1.0 -. confidence_level)) in
      if index < List.length returns && index >= 0 then List.nth_exn sorted_returns index else 0.0


  let calculate_expected_shortfall returns ~confidence_level =
    let sorted_returns = List.sort returns ~compare:Float.compare in
    let var_index = Int.of_float (Float.of_int (List.length returns) *. (1.0 -. confidence_level)) in
    let tail_returns = List.take sorted_returns var_index in
      if List.is_empty tail_returns then 0.0
      else List.fold tail_returns ~init:0.0 ~f:( +. ) /. Float.of_int (List.length tail_returns)


  let calculate_maximum_drawdown nav_history =
    let rec find_max_dd peak _current_dd max_dd = function
      | [] -> max_dd
      | nav :: rest ->
        let new_peak = Float.max peak nav in
        let new_dd = if Float.(new_peak = 0.0) then 0.0 else (new_peak -. nav) /. new_peak in
        let new_max_dd = Float.max max_dd new_dd in
          find_max_dd new_peak new_dd new_max_dd rest in
      match nav_history with [] -> 0.0 | first :: rest -> find_max_dd first 0.0 0.0 rest


  let calculate_risk_metrics portfolio ~return_history ~benchmark_returns =
    let volatility = calculate_portfolio_volatility return_history in
    let var_95 = calculate_var return_history ~confidence_level:0.95 in
    let es_95 = calculate_expected_shortfall return_history ~confidence_level:0.95 in

    let nav_history =
      List.fold return_history ~init:[ portfolio.initial_capital ] ~f:(fun acc ret ->
        let last_nav = List.hd_exn acc in
          (last_nav *. (1.0 +. (ret /. 100.0))) :: acc)
      |> List.rev in
    let max_dd = calculate_maximum_drawdown nav_history in

    let sharpe_ratio =
      if Float.(volatility = 0.0) then None
      else
        let mean_return =
          List.fold return_history ~init:0.0 ~f:( +. ) /. Float.of_int (List.length return_history)
        in
          Some (mean_return /. volatility) in

    let beta =
      match benchmark_returns with
      | Some bench_rets when Int.(List.length bench_rets = List.length return_history) ->
        let mean_portfolio =
          List.fold return_history ~init:0.0 ~f:( +. ) /. Float.of_int (List.length return_history)
        in
        let mean_benchmark =
          List.fold bench_rets ~init:0.0 ~f:( +. ) /. Float.of_int (List.length bench_rets) in
        let covariance =
          List.fold2_exn return_history bench_rets ~init:0.0 ~f:(fun acc p_ret b_ret ->
            acc +. ((p_ret -. mean_portfolio) *. (b_ret -. mean_benchmark)))
          /. Float.of_int (List.length return_history) in
        let benchmark_variance =
          List.fold bench_rets ~init:0.0 ~f:(fun acc b_ret ->
            acc +. ((b_ret -. mean_benchmark) *. (b_ret -. mean_benchmark)))
          /. Float.of_int (List.length bench_rets) in
          if Float.(benchmark_variance = 0.0) then None else Some (covariance /. benchmark_variance)
      | _ -> None in

    {
      value_at_risk_95 = var_95;
      expected_shortfall_95 = es_95;
      maximum_drawdown = max_dd;
      volatility;
      sharpe_ratio;
      beta;
    }
end

module Portfolio_analytics = struct
  type performance_summary = {
    total_return : float;
    annualized_return : float;
    volatility : float;
    sharpe_ratio : float;
    max_drawdown : float;
    win_rate : float;
    profit_factor : float;
    total_trades : int;
  }
  [@@deriving sexp]

  let calculate_performance_summary portfolio ~return_history ~holding_period_days =
    let total_return = portfolio_return portfolio in
    let annualized_return =
      if Float.(holding_period_days > 0.0) then total_return *. (365.0 /. holding_period_days)
      else 0.0 in

    let volatility = Risk_metrics.calculate_portfolio_volatility return_history in
    let sharpe_ratio = if Float.(volatility = 0.0) then 0.0 else total_return /. volatility in
    let nav_history_analytics =
      List.fold return_history ~init:[ portfolio.initial_capital ] ~f:(fun acc ret ->
        let last_nav = List.hd_exn acc in
          (last_nav *. (1.0 +. (ret /. 100.0))) :: acc)
      |> List.rev in
    let max_drawdown = Risk_metrics.calculate_maximum_drawdown nav_history_analytics in

    let positive_returns = List.count return_history ~f:(fun ret -> Float.(ret > 0.0)) in
    let win_rate =
      if List.is_empty return_history then 0.0
      else Float.of_int positive_returns /. Float.of_int (List.length return_history) *. 100.0 in

    let gross_profits =
      List.fold return_history ~init:0.0 ~f:(fun acc ret ->
        if Float.(ret > 0.0) then acc +. ret else acc) in
    let gross_losses =
      Float.abs
        (List.fold return_history ~init:0.0 ~f:(fun acc ret ->
           if Float.(ret < 0.0) then acc +. ret else acc)) in
    let profit_factor =
      if Float.(gross_losses = 0.0) then Float.infinity else gross_profits /. gross_losses in

    {
      total_return;
      annualized_return;
      volatility;
      sharpe_ratio;
      max_drawdown;
      win_rate;
      profit_factor;
      total_trades = Map.Poly.length portfolio.positions;
    }
end
