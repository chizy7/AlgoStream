open Base
module Timestamp = Algostream_domain_common.Timestamp

type pair_relationship =
  | Cointegrated of {
      half_life : float;
      hedge_ratio : float;
      adf_statistic : float;
      p_value : float;
    }
  | Correlated of {
      correlation : float;
      rolling_window : int;
      significance_level : float;
    }
[@@deriving sexp]

type pair_state =
  | Normal
  | Diverged of {
      z_score : float;
      entry_time : Timestamp.t;
    }
  | Converging of {
      z_score : float;
      entry_time : Timestamp.t;
    }
  | Position_open of {
      long_symbol : string;
      short_symbol : string;
      entry_spread : float;
      entry_time : Timestamp.t;
    }
[@@deriving sexp]

type trading_pair = {
  symbol_a : string;
  symbol_b : string;
  relationship : pair_relationship;
  current_state : pair_state;
  spread_series : float list;
  z_score_series : float list;
  entry_threshold : float;
  exit_threshold : float;
  stop_loss_threshold : float;
  lookback_window : int;
  created_at : Timestamp.t;
  updated_at : Timestamp.t;
}
[@@deriving sexp]

let create_pair ~symbol_a ~symbol_b ~relationship ~entry_threshold ~exit_threshold
  ~stop_loss_threshold ~lookback_window =
  let now = Timestamp.now () in
    {
      symbol_a;
      symbol_b;
      relationship;
      current_state = Normal;
      spread_series = [];
      z_score_series = [];
      entry_threshold;
      exit_threshold;
      stop_loss_threshold;
      lookback_window;
      created_at = now;
      updated_at = now;
    }


let calculate_spread pair ~price_a ~price_b =
  match pair.relationship with
  | Cointegrated { hedge_ratio; _ } -> price_a -. (hedge_ratio *. price_b)
  | Correlated _ -> price_a -. price_b


let calculate_z_score values =
  if List.length values < 2 then 0.0
  else
    let mean = List.fold values ~init:0.0 ~f:( +. ) /. Float.of_int (List.length values) in
    let variance =
      List.fold values ~init:0.0 ~f:(fun acc v -> acc +. ((v -. mean) *. (v -. mean)))
      /. (Float.of_int (List.length values) -. 1.0) in
    let std_dev = Float.sqrt variance in
      if Float.(std_dev = 0.0) then 0.0
      else
        let latest_value = List.last_exn values in
          (latest_value -. mean) /. std_dev


let update_pair_data pair ~price_a ~price_b =
  let spread = calculate_spread pair ~price_a ~price_b in
  let new_spread_series = List.take (spread :: pair.spread_series) pair.lookback_window in
  let z_score = calculate_z_score new_spread_series in
  let new_z_score_series = List.take (z_score :: pair.z_score_series) pair.lookback_window in

  let new_state =
    match pair.current_state with
    | Normal ->
      if Float.(Float.abs z_score >= pair.entry_threshold) then
        Diverged { z_score; entry_time = Timestamp.now () }
      else Normal
    | Diverged { entry_time; _ } ->
      if Float.(Float.abs z_score <= pair.exit_threshold) then Converging { z_score; entry_time }
      else if Float.(Float.abs z_score >= pair.stop_loss_threshold) then Normal
      else Diverged { z_score; entry_time }
    | Converging { entry_time; _ } ->
      if Float.(Float.abs z_score <= pair.exit_threshold) then Normal
      else Converging { z_score; entry_time }
    | Position_open { long_symbol; short_symbol; entry_spread; entry_time } ->
      if Float.(Float.abs z_score <= pair.exit_threshold) then Normal
      else if Float.(Float.abs z_score >= pair.stop_loss_threshold) then Normal
      else Position_open { long_symbol; short_symbol; entry_spread; entry_time } in

  {
    pair with
    spread_series = new_spread_series;
    z_score_series = new_z_score_series;
    current_state = new_state;
    updated_at = Timestamp.now ();
  }


let should_enter_trade pair =
  match pair.current_state with Diverged { z_score; _ } -> Some z_score | _ -> None


let should_exit_trade pair =
  match pair.current_state with
  | Position_open _ ->
    (match List.hd pair.z_score_series with
    | Some z when Float.(Float.abs z <= pair.exit_threshold) -> true
    | Some z when Float.(Float.abs z >= pair.stop_loss_threshold) -> true
    | _ -> false)
  | Converging _ -> true
  | _ -> false


let get_trade_signal pair =
  match should_enter_trade pair with
  | Some z_score when Float.(z_score > 0.0) -> Some (`Short pair.symbol_a, `Long pair.symbol_b)
  | Some z_score when Float.(z_score < 0.0) -> Some (`Long pair.symbol_a, `Short pair.symbol_b)
  | _ -> None


module Statistics = struct
  let calculate_correlation values_a values_b =
    if Int.(List.length values_a <> List.length values_b) || List.length values_a < 2 then 0.0
    else
      let n = Float.of_int (List.length values_a) in
      let mean_a = List.fold values_a ~init:0.0 ~f:( +. ) /. n in
      let mean_b = List.fold values_b ~init:0.0 ~f:( +. ) /. n in

      let numerator =
        List.fold2_exn values_a values_b ~init:0.0 ~f:(fun acc a b ->
          acc +. ((a -. mean_a) *. (b -. mean_b))) in

      let sum_sq_a =
        List.fold values_a ~init:0.0 ~f:(fun acc a -> acc +. ((a -. mean_a) *. (a -. mean_a))) in
      let sum_sq_b =
        List.fold values_b ~init:0.0 ~f:(fun acc b -> acc +. ((b -. mean_b) *. (b -. mean_b))) in

      let denominator = Float.sqrt (sum_sq_a *. sum_sq_b) in
        if Float.(denominator = 0.0) then 0.0 else numerator /. denominator


  let calculate_adf_statistic price_series =
    if List.length price_series < 3 then (0.0, 1.0)
    else
      let n = List.length price_series in
      let diffs = List.map2_exn (List.drop price_series 1) price_series ~f:(fun p1 p0 -> p1 -. p0) in
      let lagged_levels = List.drop_last_exn price_series in

      let mean_diff = List.fold diffs ~init:0.0 ~f:( +. ) /. Float.of_int (List.length diffs) in
      let mean_level =
        List.fold lagged_levels ~init:0.0 ~f:( +. ) /. Float.of_int (List.length lagged_levels)
      in

      let numerator =
        List.fold2_exn diffs lagged_levels ~init:0.0 ~f:(fun acc diff level ->
          acc +. ((diff -. mean_diff) *. (level -. mean_level))) in

      let denominator =
        List.fold lagged_levels ~init:0.0 ~f:(fun acc level ->
          acc +. ((level -. mean_level) *. (level -. mean_level))) in

      if Float.(denominator = 0.0) then (0.0, 1.0)
      else
        let beta = numerator /. denominator in
        let residuals =
          List.map2_exn diffs lagged_levels ~f:(fun diff level ->
            diff -. mean_diff -. (beta *. (level -. mean_level))) in

        let mse =
          List.fold residuals ~init:0.0 ~f:(fun acc r -> acc +. (r *. r)) /. Float.of_int (n - 2)
        in
        let se_beta = Float.sqrt (mse /. denominator) in
        let t_stat = if Float.(se_beta = 0.0) then 0.0 else beta /. se_beta in

        let p_value = if Float.(Float.abs t_stat < 1.96) then 0.05 else 0.01 in
          (t_stat, p_value)


  let estimate_half_life spread_series =
    if List.length spread_series < 3 then Float.infinity
    else
      let lagged_spreads = List.drop_last_exn spread_series in
      let current_spreads = List.drop spread_series 1 in
      let changes = List.map2_exn current_spreads lagged_spreads ~f:(fun curr lag -> curr -. lag) in

      let mean_change =
        List.fold changes ~init:0.0 ~f:( +. ) /. Float.of_int (List.length changes) in
      let mean_level =
        List.fold lagged_spreads ~init:0.0 ~f:( +. ) /. Float.of_int (List.length lagged_spreads)
      in

      let numerator =
        List.fold2_exn changes lagged_spreads ~init:0.0 ~f:(fun acc change level ->
          acc +. ((change -. mean_change) *. (level -. mean_level))) in

      let denominator =
        List.fold lagged_spreads ~init:0.0 ~f:(fun acc level ->
          acc +. ((level -. mean_level) *. (level -. mean_level))) in

      if Float.(denominator = 0.0) then Float.infinity
      else
        let lambda = -1.0 *. (numerator /. denominator) in
          if Float.(lambda <= 0.0) then Float.infinity else Float.log 2.0 /. lambda


  type cointegration_result = {
    is_cointegrated : bool;
    trace_statistic : float;
    critical_value_95 : float;
    correlation : float;
  }
  [@@deriving sexp]

  let johansen_test values_a values_b =
    let correlation = calculate_correlation values_a values_b in
    let _adf_a, p_a = calculate_adf_statistic values_a in
    let _adf_b, p_b = calculate_adf_statistic values_b in

    let is_cointegrated = Float.(correlation > 0.7) && Float.(p_a < 0.05) && Float.(p_b < 0.05) in
    let trace_statistic = Float.abs correlation *. Float.of_int (List.length values_a) in

    { is_cointegrated; trace_statistic; critical_value_95 = 15.41; correlation }
end

module Pair_analytics = struct
  type performance_metrics = {
    total_trades : int;
    profitable_trades : int;
    win_rate : float;
    average_holding_period : float;
    max_drawdown : float;
    sharpe_ratio : float;
    average_spread_reversion_time : float;
  }
  [@@deriving sexp]

  let calculate_performance _pair ~trade_history =
    let total_trades = List.length trade_history in
    let profitable_trades = List.count trade_history ~f:(fun pnl -> Float.(pnl > 0.0)) in
    let win_rate =
      if total_trades = 0 then 0.0
      else Float.of_int profitable_trades /. Float.of_int total_trades *. 100.0 in

    let average_pnl =
      if total_trades = 0 then 0.0
      else List.fold trade_history ~init:0.0 ~f:( +. ) /. Float.of_int total_trades in

    let volatility =
      if List.length trade_history < 2 then 0.0
      else
        let variance =
          List.fold trade_history ~init:0.0 ~f:(fun acc pnl ->
            acc +. ((pnl -. average_pnl) *. (pnl -. average_pnl)))
          /. (Float.of_int (List.length trade_history) -. 1.0) in
          Float.sqrt variance in

    let sharpe_ratio = if Float.(volatility = 0.0) then 0.0 else average_pnl /. volatility in

    let max_drawdown =
      List.fold trade_history ~init:(0.0, 0.0, 0.0) ~f:(fun (running_pnl, peak, max_dd) pnl ->
        let new_running = running_pnl +. pnl in
        let new_peak = Float.max peak new_running in
        let drawdown = new_peak -. new_running in
        let new_max_dd = Float.max max_dd drawdown in
          (new_running, new_peak, new_max_dd))
      |> fun (_, _, dd) -> dd in

    {
      total_trades;
      profitable_trades;
      win_rate;
      average_holding_period = 0.0;
      max_drawdown;
      sharpe_ratio;
      average_spread_reversion_time = 0.0;
    }
end
