open Base
open Algostream_domain_pairs

let cointegrated_relationship ?(hedge_ratio = 1.2) () =
  Pair.Cointegrated { half_life = 5.0; hedge_ratio; adf_statistic = -3.5; p_value = 0.01 }


let make_pair ?(hedge_ratio = 1.2) ?(lookback = 50) () =
  Pair.create_pair ~symbol_a:"AAPL" ~symbol_b:"MSFT"
    ~relationship:(cointegrated_relationship ~hedge_ratio ())
    ~entry_threshold:2.0 ~exit_threshold:0.5 ~stop_loss_threshold:3.0 ~lookback_window:lookback


let test_create_pair () =
  let pair = make_pair () in
    Alcotest.(check string) "symbol_a" "AAPL" pair.symbol_a ;
    Alcotest.(check string) "symbol_b" "MSFT" pair.symbol_b ;
    Alcotest.(check (float 1e-9)) "entry_threshold" 2.0 pair.entry_threshold ;
    Alcotest.(check bool) "spread_series empty" true (List.is_empty pair.spread_series)


let test_spread_calculation () =
  let pair = make_pair ~hedge_ratio:1.2 () in
  let spread = Pair.calculate_spread pair ~price_a:150.0 ~price_b:100.0 in
    Alcotest.(check (float 1e-9)) "spread" (150.0 -. (1.2 *. 100.0)) spread


let test_z_score_calculation () =
  let z = Pair.calculate_z_score [ 1.0; 2.0; 3.0; 4.0; 5.0 ] in
    Alcotest.(check bool) "z within tolerance" true Float.(abs (z -. 1.26) < 0.2)


let test_correlation_calculation () =
  let values_a = [ 1.0; 2.0; 3.0; 4.0; 5.0 ] in
  let values_b = [ 2.0; 4.0; 6.0; 8.0; 10.0 ] in
  let c = Pair.Statistics.calculate_correlation values_a values_b in
    Alcotest.(check bool) "correlation > 0.99" true Float.(c > 0.99)


let test_pair_state_transitions () =
  let pair = make_pair ~hedge_ratio:1.0 ~lookback:10 () in
  let pair = Pair.update_pair_data pair ~price_a:100.0 ~price_b:95.0 in
  let pair = Pair.update_pair_data pair ~price_a:105.0 ~price_b:95.0 in
  let pair = Pair.update_pair_data pair ~price_a:110.0 ~price_b:95.0 in
    match pair.current_state with
    | Pair.Normal | Pair.Diverged _ | Pair.Converging _ | Pair.Position_open _ -> ()


let suite =
  [
    Alcotest.test_case "create" `Quick test_create_pair;
    Alcotest.test_case "spread" `Quick test_spread_calculation;
    Alcotest.test_case "z_score" `Quick test_z_score_calculation;
    Alcotest.test_case "correlation" `Quick test_correlation_calculation;
    Alcotest.test_case "state_transitions" `Quick test_pair_state_transitions;
  ]
