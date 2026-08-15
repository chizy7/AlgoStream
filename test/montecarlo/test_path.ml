module MC = Algostream_montecarlo
module Rng = Algostream_rng.Rng
module Garch11 = Algostream_advanced_models.Garch11
module Hypothesis_test = Algostream_advanced_models.Hypothesis_test

let log_returns prices =
  Array.init (Array.length prices - 1) (fun i -> log (prices.(i + 1) /. prices.(i)))


let mean a = Array.fold_left ( +. ) 0.0 a /. float_of_int (Array.length a)

let stdev a =
  let m = mean a in
  let n = Array.length a in
    sqrt (Array.fold_left (fun s x -> s +. ((x -. m) *. (x -. m))) 0.0 a /. float_of_int (n - 1))


let test_gbm_log_returns_are_normal () =
  let rng = Rng.create ~seed:3 in
  let prices = MC.Path.gbm ~rng ~s0:100.0 ~mu:0.0 ~sigma:0.2 ~n:20_000 ~dt:(1.0 /. 252.0) in
  let r = log_returns prices in
  let jb = Hypothesis_test.jarque_bera ~sample:r in
    (* GBM log-returns are exactly normal by construction, so JB must not reject. *)
    Alcotest.(check bool)
      (Printf.sprintf "Jarque-Bera p=%.4f does not reject normality" jb.Hypothesis_test.p_value)
      true
      (jb.Hypothesis_test.p_value > 0.01)


let test_gbm_volatility_matches_input () =
  let rng = Rng.create ~seed:5 in
  let dt = 1.0 /. 252.0 in
  let prices = MC.Path.gbm ~rng ~s0:100.0 ~mu:0.05 ~sigma:0.30 ~n:50_000 ~dt in
  let r = log_returns prices in
  let realized_ann = stdev r /. sqrt dt in
    Alcotest.(check bool)
      (Printf.sprintf "realized annualized vol %.4f is near the 0.30 input" realized_ann)
      true
      (Float.abs (realized_ann -. 0.30) < 0.01)


(* THE GARCH property. Squared returns must be autocorrelated (volatility clusters) while raw
   returns must not. An iid bootstrap fails the first of these, which is exactly why the sampler
   exists. *)
let test_garch_exhibits_volatility_clustering () =
  let rng = Rng.create ~seed:23 in
  (* Persistent process: alpha + beta = 0.95. *)
  let fit =
    {
      Garch11.params = { omega = 2e-6; alpha = 0.10; beta = 0.85 };
      log_likelihood = 0.0;
      iter = 0;
      converged = true;
      long_run_variance = 2e-6 /. 0.05;
    } in
  let model = Garch11.of_fit fit ~last_return:0.0 ~last_variance:(2e-6 /. 0.05) in
  let r = MC.Path.garch_returns ~rng ~model ~n:20_000 in
  let squared = Array.map (fun x -> x *. x) r in
  let lb_raw = Hypothesis_test.ljung_box ~residuals:r ~lags:10 in
  let lb_sq = Hypothesis_test.ljung_box ~residuals:squared ~lags:10 in
    Alcotest.(check bool)
      (Printf.sprintf "raw returns show no autocorrelation (Ljung-Box p=%.4f)"
         lb_raw.Hypothesis_test.p_value)
      true
      (lb_raw.Hypothesis_test.p_value > 0.01) ;
    Alcotest.(check bool)
      (Printf.sprintf "SQUARED returns are autocorrelated (Ljung-Box p=%.6f) — clustering"
         lb_sq.Hypothesis_test.p_value)
      true
      (lb_sq.Hypothesis_test.p_value < 0.01)


let test_multivariate_recovers_correlation () =
  let rng = Rng.create ~seed:29 in
  let sigma = 0.02 in
  let rho = 0.7 in
  let cov =
    [| [| sigma *. sigma; rho *. sigma *. sigma |]; [| rho *. sigma *. sigma; sigma *. sigma |] |]
  in
    match
      MC.Path.multivariate_gbm ~rng ~s0:[| 100.0; 50.0 |] ~mu:[| 0.0; 0.0 |] ~cov ~n:100_000 ~dt:1.0
    with
    | Error _ -> Alcotest.fail "multivariate_gbm failed on a valid covariance"
    | Ok paths ->
      let a = log_returns paths.(0) and b = log_returns paths.(1) in
      let ma = mean a and mb = mean b in
      let n = min (Array.length a) (Array.length b) in
      let sab = ref 0.0 and saa = ref 0.0 and sbb = ref 0.0 in
        for i = 0 to n - 1 do
          let da = a.(i) -. ma and db = b.(i) -. mb in
            sab := !sab +. (da *. db) ;
            saa := !saa +. (da *. da) ;
            sbb := !sbb +. (db *. db)
        done ;
        let realized = !sab /. sqrt (!saa *. !sbb) in
          Alcotest.(check bool)
            (Printf.sprintf "realized correlation %.4f is near the 0.70 input" realized)
            true
            (Float.abs (realized -. rho) < 0.02)


let test_multivariate_rejects_bad_covariance () =
  let rng = Rng.create ~seed:31 in
  (* Correlation of 2.0 is not a valid covariance — must fail rather than produce nonsense. *)
  let cov = [| [| 1.0; 2.0 |]; [| 2.0; 1.0 |] |] in
    match
      MC.Path.multivariate_gbm ~rng ~s0:[| 1.0; 1.0 |] ~mu:[| 0.0; 0.0 |] ~cov ~n:10 ~dt:1.0
    with
    | Error _ -> Alcotest.(check bool) "rejected an indefinite covariance" true true
    | Ok _ -> Alcotest.fail "expected an error on an indefinite covariance"


let test_jump_diffusion_has_fatter_tails () =
  let rng1 = Rng.create ~seed:37 in
  let rng2 = Rng.create ~seed:37 in
  let plain = MC.Path.gbm ~rng:rng1 ~s0:100.0 ~mu:0.0 ~sigma:0.2 ~n:20_000 ~dt:0.004 in
  let jumpy =
    MC.Path.merton_jump_diffusion ~rng:rng2 ~s0:100.0 ~mu:0.0 ~sigma:0.2 ~lambda:10.0
      ~jump_mu:(-0.02) ~jump_sigma:0.05 ~n:20_000 ~dt:0.004 in
  let kurt a =
    let r = log_returns a in
    let m = mean r and s = stdev r in
    let n = float_of_int (Array.length r) in
      (Array.fold_left (fun acc x -> acc +. (((x -. m) /. s) ** 4.0)) 0.0 r /. n) -. 3.0 in
  let k_plain = kurt plain and k_jump = kurt jumpy in
    Alcotest.(check bool)
      (Printf.sprintf "jump-diffusion excess kurtosis %.2f exceeds plain GBM's %.2f" k_jump k_plain)
      true (k_jump > k_plain)


let test_to_records_produces_quotes () =
  let prices = [| 100.0; 101.0; 102.0 |] in
  let recs =
    MC.Path.to_records ~symbol:"SYN" ~prices ~start_ts_ns:0L ~step_ns:1_000_000_000L
      ~spread_bps:10.0 () in
    Alcotest.(check int) "one record per price" 3 (Array.length recs) ;
    match recs.(0) with
    | Algostream_backtest.Data_source.Tick t ->
      Alcotest.(check (float 1e-9)) "price" 100.0 t.price ;
      (match (t.bid, t.ask) with
      | Some b, Some a ->
        (* 10 bps total width around 100 => bid 99.95, ask 100.05 *)
        Alcotest.(check (float 1e-6)) "bid" 99.95 b ;
        Alcotest.(check (float 1e-6)) "ask" 100.05 a
      | _ -> Alcotest.fail "expected a two-sided quote")
    | _ -> Alcotest.fail "expected a Tick"


let suite =
  [
    Alcotest.test_case "gbm_log_returns_are_normal" `Quick test_gbm_log_returns_are_normal;
    Alcotest.test_case "gbm_volatility_matches_input" `Quick test_gbm_volatility_matches_input;
    Alcotest.test_case "garch_exhibits_volatility_clustering" `Quick
      test_garch_exhibits_volatility_clustering;
    Alcotest.test_case "multivariate_recovers_correlation" `Quick
      test_multivariate_recovers_correlation;
    Alcotest.test_case "multivariate_rejects_bad_covariance" `Quick
      test_multivariate_rejects_bad_covariance;
    Alcotest.test_case "jump_diffusion_has_fatter_tails" `Quick test_jump_diffusion_has_fatter_tails;
    Alcotest.test_case "to_records_produces_quotes" `Quick test_to_records_produces_quotes;
  ]
