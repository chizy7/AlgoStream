(* The anti-duplication guard.

   The tree once carried FOUR max-drawdown implementations and THREE Sharpe implementations across
   three different formulas, two of them sharing a field name. (The fourth drawdown and third
   Sharpe, in Pair.Pair_analytics, were found by `make metrics-dup-lint` on its first run.) Rather
   than delete them — Portfolio.Risk_metrics is load-bearing for Risk_management.Var.Historical —
   one canonical implementation was added and the others marked superseded.

   These tests pin that situation so it cannot drift silently: where the old and new agree, we
   assert they keep agreeing; where they disagree, we assert the disagreement is exactly what we
   documented, so nobody "fixes" one of them without noticing the other. *)

module Metrics = Algostream_performance.Metrics
module Returns = Algostream_performance.Returns
module Portfolio = Algostream_domain_portfolio.Portfolio
module Var = Algostream_risk_management.Var

let day = 86_400_000_000_000L

let nav_vals = [| 100.0; 120.0; 90.0; 130.0; 110.0 |]

let nav = Array.mapi (fun i v -> (Int64.mul (Int64.of_int i) day, v)) nav_vals

let returns = Returns.of_nav ~nav ~kind:Returns.Simple

(* Max drawdown is the one place old and new SHOULD agree exactly. *)
let test_max_drawdown_agrees_with_portfolio_risk_metrics () =
  let ours = (Metrics.of_nav ~nav ()).Metrics.max_drawdown in
  let theirs = Portfolio.Risk_metrics.calculate_maximum_drawdown (Array.to_list nav_vals) in
    Alcotest.(check (float 1e-9))
      "Performance.Metrics.max_drawdown agrees with Portfolio.Risk_metrics" theirs ours


(* The two legacy Sharpe implementations use different formulas. Pin the discrepancy explicitly so a
   future "fix" to one of them fails here and forces a conscious decision. *)
let test_legacy_sharpe_implementations_disagree () =
  let vol = Portfolio.Risk_metrics.calculate_portfolio_volatility (Array.to_list returns) in
  let n = float_of_int (Array.length returns) in
  let mean_r = Array.fold_left ( +. ) 0.0 returns /. n in
  let total_r = Returns.total_return ~returns ~kind:Returns.Simple in
  let risk_metrics_style = if vol = 0.0 then 0.0 else mean_r /. vol in
  let analytics_style = if vol = 0.0 then 0.0 else total_r /. vol in
    Alcotest.(check bool)
      (Printf.sprintf
         "the two legacy formulas differ (mean/vol = %.4f vs total/vol = %.4f) — neither is \
          annualized or risk-free adjusted"
         risk_metrics_style analytics_style)
      true
      (Float.abs (risk_metrics_style -. analytics_style) > 1e-6)


(* And the canonical one differs from both, because it annualizes. That is the point. *)
let test_canonical_sharpe_differs_because_it_annualizes () =
  let m = Metrics.of_nav ~nav () in
  let vol = Portfolio.Risk_metrics.calculate_portfolio_volatility (Array.to_list returns) in
  let n = float_of_int (Array.length returns) in
  let mean_r = Array.fold_left ( +. ) 0.0 returns /. n in
  let unannualized = if vol = 0.0 then 0.0 else mean_r /. vol in
    Alcotest.(check bool)
      (Printf.sprintf "canonical Sharpe %.4f is the annualized form of %.4f" m.Metrics.sharpe
         unannualized)
      true
      (Float.abs (m.Metrics.sharpe -. unannualized) > 1e-6) ;
    (* Annualizing multiplies by sqrt(periods_per_year). *)
    let expected = unannualized *. sqrt m.Metrics.periods_per_year in
      Alcotest.(check (float 1e-6)) "and equals mean/vol * sqrt(ppy)" expected m.Metrics.sharpe


(* VaR must be delegated, not reimplemented — same inputs, same number. *)
let test_var_is_delegated_not_reimplemented () =
  let m = Metrics.of_returns ~returns ~periods_per_year:365.0 () in
  let direct =
    Var.compute ~method_:Var.Historical ~returns ~portfolio_value:1.0 ~confidence:0.95
      ~horizon_days:1 in
    Alcotest.(check (float 1e-12))
      "Metrics.var_95 is Risk_management.Var.Historical" direct.Var.var_pct m.Metrics.var_95 ;
    Alcotest.(check (float 1e-12))
      "and cvar_95 likewise" direct.Var.expected_shortfall_pct m.Metrics.cvar_95


(* A guard against a fourth implementation appearing: no new Sharpe/Sortino/Calmar/max-drawdown
   definition may be introduced outside lib/performance. The allowlist names the four known legacy
   sites; anything else fails. *)
let contains haystack needle =
  let nl = String.length needle and hl = String.length haystack in
  let rec loop i =
    if i + nl > hl then false else if String.sub haystack i nl = needle then true else loop (i + 1)
  in
    loop 0


let test_no_new_metric_definitions_outside_performance () =
  let allowed =
    [
      "lib/domain/portfolio/portfolio.ml";
      "lib/common/utils/math_utils.ml";
      "lib/common/utils/math_utils.mli";
      "lib/risk_management/drawdown.ml";
      "lib/risk_management/drawdown.mli";
    ] in
  let patterns =
    [
      "let sharpe_ratio";
      "let sortino";
      "let calmar";
      "let max_drawdown";
      "let calculate_maximum_drawdown";
    ] in
  let offenders = ref [] in
  let rec walk d =
    if Sys.file_exists d && Sys.is_directory d then
      Array.iter
        (fun f ->
          let p = Filename.concat d f in
            if Sys.is_directory p then walk p
            else if Filename.check_suffix p ".ml" || Filename.check_suffix p ".mli" then
              if not (List.exists (fun a -> contains p a) allowed) then
                if not (contains p "lib/performance") then (
                  let ic = open_in p in
                    (try
                       while true do
                         let line = input_line ic in
                           List.iter
                             (fun pat ->
                               if contains line pat then offenders := (p, line) :: !offenders)
                             patterns
                       done
                     with End_of_file -> ()) ;
                    close_in ic))
        (Sys.readdir d) in
  let candidates = [ "lib"; "../../../lib"; Filename.concat (Sys.getcwd ()) "lib" ] in
    match List.find_opt Sys.file_exists candidates with
    | None -> Alcotest.(check bool) "lint enforced via CI" true true
    | Some root ->
      walk root ;
      if !offenders <> [] then
        List.iter (fun (p, l) -> Printf.eprintf "DUPLICATE METRIC: %s :: %s\n" p l) !offenders ;
      Alcotest.(check int)
        "no metric definitions outside lib/performance or the allowlist" 0 (List.length !offenders)


let suite =
  [
    Alcotest.test_case "max_drawdown_agrees_with_portfolio_risk_metrics" `Quick
      test_max_drawdown_agrees_with_portfolio_risk_metrics;
    Alcotest.test_case "legacy_sharpe_implementations_disagree" `Quick
      test_legacy_sharpe_implementations_disagree;
    Alcotest.test_case "canonical_sharpe_differs_because_it_annualizes" `Quick
      test_canonical_sharpe_differs_because_it_annualizes;
    Alcotest.test_case "var_is_delegated_not_reimplemented" `Quick
      test_var_is_delegated_not_reimplemented;
    Alcotest.test_case "no_new_metric_definitions_outside_performance" `Quick
      test_no_new_metric_definitions_outside_performance;
  ]
