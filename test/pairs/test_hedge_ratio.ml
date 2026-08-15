open Algostream_pairs

let test_rolling_ols_converges () =
  let cfg = { Config.default with beta_mode = Rolling_ols; beta_window = 256 } in
  let hr = Hedge_ratio.create cfg in
  let rng = Random.State.make [| 21 |] in
    for _ = 0 to 511 do
      let x = Helpers.normal_sample rng in
      let y = (2.0 *. x) +. (0.05 *. Helpers.normal_sample rng) in
      let _ = Hedge_ratio.update hr ~x ~y in
        ()
    done ;
    Alcotest.(check (float 0.1))
      (Printf.sprintf "beta=%g near 2.0" (Hedge_ratio.beta hr))
      2.0 (Hedge_ratio.beta hr)


let test_static_mode () =
  let cfg = { Config.default with beta_mode = Static 7.5 } in
  let hr = Hedge_ratio.create cfg in
  let _ = Hedge_ratio.update hr ~x:1.0 ~y:100.0 in
    Alcotest.(check (float 1e-9)) "static beta unchanged" 7.5 (Hedge_ratio.beta hr) ;
    Alcotest.(check (float 1e-9)) "static intercept = 0" 0.0 (Hedge_ratio.intercept hr)


let test_kalman_smoother_tracks () =
  let cfg = { Config.default with beta_mode = Kalman_smoothed; beta_window = 128 } in
  let hr = Hedge_ratio.create cfg in
  let rng = Random.State.make [| 22 |] in
    for _ = 0 to 511 do
      let x = Helpers.normal_sample rng in
      let y = (3.0 *. x) +. (0.05 *. Helpers.normal_sample rng) in
      let _ = Hedge_ratio.update hr ~x ~y in
        ()
    done ;
    Alcotest.(check (float 0.25))
      (Printf.sprintf "kalman beta=%g near 3.0" (Hedge_ratio.beta hr))
      3.0 (Hedge_ratio.beta hr)


let test_frozen_on_flat_regressor () =
  let cfg = { Config.default with beta_mode = Rolling_ols; beta_window = 32 } in
  let hr = Hedge_ratio.create cfg in
    for _ = 0 to 63 do
      let _ = Hedge_ratio.update hr ~x:5.0 ~y:10.0 in
        ()
    done ;
    Alcotest.(check bool) "frozen counter > 0" true (Hedge_ratio.beta_frozen_ticks hr > 0)


let suite =
  [
    Alcotest.test_case "rolling_ols_converges" `Quick test_rolling_ols_converges;
    Alcotest.test_case "static_mode" `Quick test_static_mode;
    Alcotest.test_case "kalman_smoother_tracks" `Quick test_kalman_smoother_tracks;
    Alcotest.test_case "frozen_on_flat_regressor" `Quick test_frozen_on_flat_regressor;
  ]
