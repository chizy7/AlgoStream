module Metrics = Algostream_performance.Metrics
module Returns = Algostream_performance.Returns

let day = 86_400_000_000_000L

let nav_of vals = Array.mapi (fun i v -> (Int64.mul (Int64.of_int i) day, v)) vals

(* Hand-computable: a constant 1% per period with zero volatility. ann_return = 0.01 * 252 = 2.52;
   volatility = 0 so Sharpe must be 0, not infinity. *)
let test_zero_volatility_gives_zero_not_infinity () =
  let returns = Array.make 100 0.01 in
  let m = Metrics.of_returns ~returns ~periods_per_year:252.0 () in
    Alcotest.(check (float 1e-9)) "annualized return" 2.52 m.Metrics.ann_return ;
    Alcotest.(check (float 1e-12)) "volatility is zero" 0.0 m.Metrics.ann_volatility ;
    Alcotest.(check (float 1e-12)) "Sharpe is 0, never infinity" 0.0 m.Metrics.sharpe ;
    Alcotest.(check bool)
      "and every field is finite" true
      (Array.for_all (fun (_, v) -> Float.is_finite v) (Metrics.to_assoc m))


let test_monotone_up_has_no_drawdown_and_finite_calmar () =
  let returns = Array.make 252 0.001 in
  let m = Metrics.of_returns ~returns ~periods_per_year:252.0 () in
    Alcotest.(check (float 1e-12)) "no drawdown" 0.0 m.Metrics.max_drawdown ;
    (* Calmar divides by max drawdown; zero must give zero, not infinity. *)
    Alcotest.(check (float 1e-12)) "Calmar is 0, never infinity" 0.0 m.Metrics.calmar


let test_all_zero_returns () =
  let m = Metrics.of_returns ~returns:(Array.make 50 0.0) ~periods_per_year:252.0 () in
    Array.iter
      (fun (name, v) ->
        Alcotest.(check bool) (Printf.sprintf "%s is finite" name) true (Float.is_finite v))
      (Metrics.to_assoc m) ;
    Alcotest.(check (float 1e-12)) "total return" 0.0 m.Metrics.total_return


let test_empty_returns () =
  let m = Metrics.of_returns ~returns:[||] ~periods_per_year:252.0 () in
    Alcotest.(check int) "no periods" 0 m.Metrics.n_periods ;
    Alcotest.(check (float 1e-12)) "Sharpe 0" 0.0 m.Metrics.sharpe


(* Sharpe = (ann_return - rf) / ann_vol, computed by hand from a symmetric two-value series. *)
let test_sharpe_hand_computed () =
  (* Alternating +2% / -1%: mean 0.005, sample sd of {0.02, -0.01} repeated. *)
  let returns = Array.init 252 (fun i -> if i mod 2 = 0 then 0.02 else -0.01) in
  let ppy = 252.0 in
  let m = Metrics.of_returns ~returns ~periods_per_year:ppy () in
  let mean = Returns.mean returns in
  let sd = Returns.stddev returns in
  let expected = mean *. ppy /. (sd *. sqrt ppy) in
    Alcotest.(check (float 1e-9)) "matches the definition" expected m.Metrics.sharpe


let test_risk_free_rate_lowers_sharpe () =
  let returns = Array.init 252 (fun i -> if i mod 2 = 0 then 0.02 else -0.01) in
  let bare = Metrics.of_returns ~returns ~periods_per_year:252.0 () in
  let with_rf = Metrics.of_returns ~returns ~periods_per_year:252.0 ~risk_free_rate_ann:0.05 () in
    Alcotest.(check bool)
      (Printf.sprintf "Sharpe falls from %.4f to %.4f once a risk-free rate is charged"
         bare.Metrics.sharpe with_rf.Metrics.sharpe)
      true
      (with_rf.Metrics.sharpe < bare.Metrics.sharpe)


(* Sortino must exceed Sharpe when the downside is smaller than the total spread — the whole reason
   the ratio exists. *)
let test_sortino_exceeds_sharpe_for_upside_skew () =
  (* Many small losses, occasional large gains: downside deviation < total volatility. *)
  let returns = Array.init 252 (fun i -> if i mod 21 = 0 then 0.10 else -0.002) in
  let m = Metrics.of_returns ~returns ~periods_per_year:252.0 () in
    Alcotest.(check bool)
      (Printf.sprintf "Sortino %.4f exceeds Sharpe %.4f on upside-skewed returns" m.Metrics.sortino
         m.Metrics.sharpe)
      true
      (m.Metrics.sortino > m.Metrics.sharpe)


let test_of_nav_infers_periodicity () =
  (* Daily samples over a 24/7 calendar must infer 365 periods per year. *)
  let nav = nav_of (Array.init 100 (fun i -> 100.0 *. (1.001 ** float_of_int i))) in
  let m = Metrics.of_nav ~nav () in
    Alcotest.(check (float 1e-6)) "365 periods per year" 365.0 m.Metrics.periods_per_year ;
    Alcotest.(check int) "99 returns from 100 NAV points" 99 m.Metrics.n_periods


let test_drawdown_matches_a_hand_built_curve () =
  (* 100 -> 120 -> 90 -> 130: peak 120, trough 90 => 25% *)
  let nav = nav_of [| 100.0; 120.0; 90.0; 130.0 |] in
  let m = Metrics.of_nav ~nav () in
    Alcotest.(check (float 1e-9)) "max drawdown is 25%" 0.25 m.Metrics.max_drawdown


let test_hit_rate_and_win_loss () =
  let returns = [| 0.01; -0.02; 0.03; -0.01; 0.02 |] in
  let m = Metrics.of_returns ~returns ~periods_per_year:252.0 () in
    Alcotest.(check (float 1e-9)) "three of five periods positive" 0.6 m.Metrics.hit_rate ;
    (* mean gain = 0.02, mean loss = 0.015 => ratio 1.333 *)
    Alcotest.(check (float 1e-6)) "win/loss ratio" (0.02 /. 0.015) m.Metrics.win_loss_ratio


let test_best_and_worst () =
  let returns = [| 0.01; -0.05; 0.03 |] in
  let m = Metrics.of_returns ~returns ~periods_per_year:252.0 () in
    Alcotest.(check (float 1e-12)) "best" 0.03 m.Metrics.best_period ;
    Alcotest.(check (float 1e-12)) "worst" (-0.05) m.Metrics.worst_period


(* VaR delegates to Risk_management rather than being a fourth implementation; confirm the wiring
   produces a sane, ordered pair. *)
let test_var_delegation_is_wired () =
  let returns = Array.init 500 (fun i -> 0.001 *. sin (float_of_int i)) in
  let m = Metrics.of_returns ~returns ~periods_per_year:252.0 () in
    Alcotest.(check bool) "VaR95 is finite" true (Float.is_finite m.Metrics.var_95) ;
    Alcotest.(check bool) "CVaR95 is at least VaR95" true (m.Metrics.cvar_95 >= m.Metrics.var_95) ;
    Alcotest.(check bool) "VaR99 is at least VaR95" true (m.Metrics.var_99 >= m.Metrics.var_95)


let test_to_assoc_is_stable () =
  let a = Metrics.to_assoc (Metrics.of_returns ~returns:[| 0.01 |] ~periods_per_year:252.0 ()) in
  let b = Metrics.to_assoc (Metrics.of_returns ~returns:[| 0.02 |] ~periods_per_year:252.0 ()) in
    Alcotest.(check int) "same field count" (Array.length a) (Array.length b) ;
    Array.iteri
      (fun i (name, _) ->
        Alcotest.(check string) (Printf.sprintf "field %d name" i) name (fst b.(i)))
      a


let suite =
  [
    Alcotest.test_case "zero_volatility_gives_zero_not_infinity" `Quick
      test_zero_volatility_gives_zero_not_infinity;
    Alcotest.test_case "monotone_up_has_no_drawdown_and_finite_calmar" `Quick
      test_monotone_up_has_no_drawdown_and_finite_calmar;
    Alcotest.test_case "all_zero_returns" `Quick test_all_zero_returns;
    Alcotest.test_case "empty_returns" `Quick test_empty_returns;
    Alcotest.test_case "sharpe_hand_computed" `Quick test_sharpe_hand_computed;
    Alcotest.test_case "risk_free_rate_lowers_sharpe" `Quick test_risk_free_rate_lowers_sharpe;
    Alcotest.test_case "sortino_exceeds_sharpe_for_upside_skew" `Quick
      test_sortino_exceeds_sharpe_for_upside_skew;
    Alcotest.test_case "of_nav_infers_periodicity" `Quick test_of_nav_infers_periodicity;
    Alcotest.test_case "drawdown_matches_a_hand_built_curve" `Quick
      test_drawdown_matches_a_hand_built_curve;
    Alcotest.test_case "hit_rate_and_win_loss" `Quick test_hit_rate_and_win_loss;
    Alcotest.test_case "best_and_worst" `Quick test_best_and_worst;
    Alcotest.test_case "var_delegation_is_wired" `Quick test_var_delegation_is_wired;
    Alcotest.test_case "to_assoc_is_stable" `Quick test_to_assoc_is_stable;
  ]
