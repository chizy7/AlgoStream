module Var = Algostream_risk_management.Var
module Quantile = Algostream_stochastic.Quantile

type t = {
  n_periods : int;
  periods_per_year : float;
  total_return : float;
  cagr : float;
  ann_return : float;
  ann_volatility : float;
  ann_downside_deviation : float;
  sharpe : float;
  sortino : float;
  calmar : float;
  omega : float;
  ulcer_index : float;
  martin_ratio : float;
  tail_ratio : float;
  max_drawdown : float;
  max_drawdown_duration_ns : int64;
  skewness : float;
  excess_kurtosis : float;
  var_95 : float;
  cvar_95 : float;
  var_99 : float;
  cvar_99 : float;
  best_period : float;
  worst_period : float;
  hit_rate : float;
  win_loss_ratio : float;
  time_in_market : float;
}

let empty =
  {
    n_periods = 0;
    periods_per_year = 0.0;
    total_return = 0.0;
    cagr = 0.0;
    ann_return = 0.0;
    ann_volatility = 0.0;
    ann_downside_deviation = 0.0;
    sharpe = 0.0;
    sortino = 0.0;
    calmar = 0.0;
    omega = 0.0;
    ulcer_index = 0.0;
    martin_ratio = 0.0;
    tail_ratio = 0.0;
    max_drawdown = 0.0;
    max_drawdown_duration_ns = 0L;
    skewness = 0.0;
    excess_kurtosis = 0.0;
    var_95 = 0.0;
    cvar_95 = 0.0;
    var_99 = 0.0;
    cvar_99 = 0.0;
    best_period = 0.0;
    worst_period = 0.0;
    hit_rate = 0.0;
    win_loss_ratio = 0.0;
    time_in_market = 0.0;
  }


(* Every ratio funnels through this so a zero denominator yields 0.0 rather than nan/infinity. The
   component fields stay populated, so a caller can always tell which case produced the zero. *)
let safe_div num den = if Float.abs den < 1e-15 then 0.0 else num /. den

let moments returns =
  let n = Array.length returns in
    if n < 2 then (0.0, 0.0)
    else
      let m = Returns.mean returns in
      let sd = Returns.stddev returns in
        if sd <= 0.0 then (0.0, 0.0)
        else
          let nf = float_of_int n in
          let m3 = ref 0.0 and m4 = ref 0.0 in
            Array.iter
              (fun r ->
                let d = (r -. m) /. sd in
                let d2 = d *. d in
                  m3 := !m3 +. (d2 *. d) ;
                  m4 := !m4 +. (d2 *. d2))
              returns ;
            (!m3 /. nf, (!m4 /. nf) -. 3.0)


(* Compound a return series into a synthetic NAV curve so the drawdown machinery has something to
   chew on when only returns are available. Timestamps are period indices, which is why of_nav is
   preferred where a real curve exists. *)
let nav_of_returns returns =
  let n = Array.length returns in
  let nav = Array.make (n + 1) (0L, 1.0) in
  let eq = ref 1.0 in
    for i = 0 to n - 1 do
      eq := !eq *. (1.0 +. returns.(i)) ;
      nav.(i + 1) <- (Int64.of_int (i + 1), !eq)
    done ;
    nav


let compute ~returns ~nav ~periods_per_year ~risk_free_rate_ann ~mar_ann =
  let n = Array.length returns in
    if n = 0 then { empty with periods_per_year }
    else
      let ppy = periods_per_year in
      let rf_pp = Returns.per_period_rate ~annual_rate:risk_free_rate_ann ~periods_per_year:ppy in
      let mar_pp = Returns.per_period_rate ~annual_rate:mar_ann ~periods_per_year:ppy in
      let mean_r = Returns.mean returns in
      let sd = Returns.stddev returns in
      let dd = Returns.downside_deviation ~returns ~mar:mar_pp in
      let ann_return = mean_r *. ppy in
      let ann_volatility = sd *. sqrt ppy in
      let ann_downside = dd *. sqrt ppy in
      let total_return = Returns.total_return ~returns ~kind:Returns.Simple in
      let years = if ppy > 0.0 then float_of_int n /. ppy else 0.0 in
      let cagr =
        if years <= 0.0 || 1.0 +. total_return <= 0.0 then 0.0
        else ((1.0 +. total_return) ** (1.0 /. years)) -. 1.0 in
      let rf_ann_equiv = rf_pp *. ppy in
      let mar_ann_equiv = mar_pp *. ppy in
      let episodes = Drawdown_analysis.episodes ~nav () in
      let max_drawdown = Drawdown_analysis.max_depth episodes in
      let max_dd_duration = Drawdown_analysis.longest_underwater_ns episodes in
      let ulcer = Drawdown_analysis.ulcer_index ~nav in
      (* Omega: ratio of probability-weighted gains to losses about the MAR. *)
      let gains = ref 0.0 and losses = ref 0.0 in
      let wins = ref 0 and win_sum = ref 0.0 and loss_sum = ref 0.0 and nonzero = ref 0 in
        Array.iter
          (fun r ->
            let d = r -. mar_pp in
              if d > 0.0 then gains := !gains +. d else losses := !losses -. d ;
              if r > 0.0 then (
                incr wins ;
                win_sum := !win_sum +. r)
              else if r < 0.0 then loss_sum := !loss_sum -. r ;
              if Float.abs r > 1e-15 then incr nonzero)
          returns ;
        let sorted = Array.copy returns in
          Array.sort compare sorted ;
          let p95 = Quantile.of_sorted ~sorted ~p:0.95 in
          let p05 = Quantile.of_sorted ~sorted ~p:0.05 in
          let skewness, excess_kurtosis = moments returns in
          (* Delegate VaR/CVaR rather than adding a fourth implementation. portfolio_value = 1.0
             makes var_dollars numerically equal to var_pct, so only the pct fields are read. *)
          let var_at c =
            let r =
              Var.compute ~method_:Var.Historical ~returns ~portfolio_value:1.0 ~confidence:c
                ~horizon_days:1 in
              (r.var_pct, r.expected_shortfall_pct) in
          let var_95, cvar_95 = var_at 0.95 in
          let var_99, cvar_99 = var_at 0.99 in
          let nf = float_of_int n in
            {
              n_periods = n;
              periods_per_year = ppy;
              total_return;
              cagr;
              ann_return;
              ann_volatility;
              ann_downside_deviation = ann_downside;
              sharpe = safe_div (ann_return -. rf_ann_equiv) ann_volatility;
              sortino = safe_div (ann_return -. mar_ann_equiv) ann_downside;
              calmar = safe_div cagr (Float.abs max_drawdown);
              omega = safe_div !gains !losses;
              ulcer_index = ulcer;
              martin_ratio = safe_div ((ann_return -. rf_ann_equiv) *. 100.0) ulcer;
              tail_ratio = safe_div (Float.abs p95) (Float.abs p05);
              max_drawdown;
              max_drawdown_duration_ns = max_dd_duration;
              skewness;
              excess_kurtosis;
              var_95;
              cvar_95;
              var_99;
              cvar_99;
              best_period = sorted.(n - 1);
              worst_period = sorted.(0);
              hit_rate = float_of_int !wins /. nf;
              win_loss_ratio =
                safe_div
                  (safe_div !win_sum (float_of_int !wins))
                  (safe_div !loss_sum (float_of_int (n - !wins)));
              time_in_market = float_of_int !nonzero /. nf;
            }


let of_returns ~returns ~periods_per_year ?(risk_free_rate_ann = 0.0) ?(mar_ann = 0.0) () =
  compute ~returns ~nav:(nav_of_returns returns) ~periods_per_year ~risk_free_rate_ann ~mar_ann


let of_nav ~nav ?(kind = Returns.Simple) ?(days_per_year = 365.0) ?(hours_per_day = 24.0)
  ?(risk_free_rate_ann = 0.0) ?(mar_ann = 0.0) () =
  let returns = Returns.of_nav ~nav ~kind in
  let interval_ns = Returns.infer_interval_ns ~nav in
  let ppy = Returns.periods_per_year ~days_per_year ~hours_per_day ~interval_ns () in
    compute ~returns ~nav ~periods_per_year:ppy ~risk_free_rate_ann ~mar_ann


let to_assoc m =
  [|
    ("n_periods", float_of_int m.n_periods);
    ("periods_per_year", m.periods_per_year);
    ("total_return", m.total_return);
    ("cagr", m.cagr);
    ("ann_return", m.ann_return);
    ("ann_volatility", m.ann_volatility);
    ("ann_downside_deviation", m.ann_downside_deviation);
    ("sharpe", m.sharpe);
    ("sortino", m.sortino);
    ("calmar", m.calmar);
    ("omega", m.omega);
    ("ulcer_index", m.ulcer_index);
    ("martin_ratio", m.martin_ratio);
    ("tail_ratio", m.tail_ratio);
    ("max_drawdown", m.max_drawdown);
    ("max_drawdown_duration_ns", Int64.to_float m.max_drawdown_duration_ns);
    ("skewness", m.skewness);
    ("excess_kurtosis", m.excess_kurtosis);
    ("var_95", m.var_95);
    ("cvar_95", m.cvar_95);
    ("var_99", m.var_99);
    ("cvar_99", m.cvar_99);
    ("best_period", m.best_period);
    ("worst_period", m.worst_period);
    ("hit_rate", m.hit_rate);
    ("win_loss_ratio", m.win_loss_ratio);
    ("time_in_market", m.time_in_market);
  |]


let to_string m =
  Printf.sprintf
    "n=%d ppy=%.1f total=%.2f%% cagr=%.2f%% vol=%.2f%%\n\
    \  sharpe=%.3f sortino=%.3f calmar=%.3f omega=%.3f martin=%.3f\n\
    \  maxDD=%.2f%% ulcer=%.2f skew=%.3f exkurt=%.3f tail=%.2f\n\
    \  VaR95=%.2f%% CVaR95=%.2f%% VaR99=%.2f%% CVaR99=%.2f%%\n\
    \  hit=%.1f%% win/loss=%.2f best=%.2f%% worst=%.2f%%"
    m.n_periods m.periods_per_year (m.total_return *. 100.0) (m.cagr *. 100.0)
    (m.ann_volatility *. 100.0) m.sharpe m.sortino m.calmar m.omega m.martin_ratio
    (m.max_drawdown *. 100.0) m.ulcer_index m.skewness m.excess_kurtosis m.tail_ratio
    (m.var_95 *. 100.0) (m.cvar_95 *. 100.0) (m.var_99 *. 100.0) (m.cvar_99 *. 100.0)
    (m.hit_rate *. 100.0) m.win_loss_ratio (m.best_period *. 100.0) (m.worst_period *. 100.0)
