open Algostream_advanced_models

let test_recovers_true_beta () =
  let kf =
    Kalman_hedge.create ~initial_alpha:0.0 ~initial_beta:1.0 ~initial_cov:10.0
      ~process_var_alpha:1e-7 ~process_var_beta:1e-4 ~measurement_var:0.25 () in
  let rng = Random.State.make [| 81 |] in
    for _ = 1 to 1000 do
      let x = Helpers.normal_sample rng *. 10.0 in
      let y = (2.0 *. x) +. (0.5 *. Helpers.normal_sample rng) in
      let _ = Kalman_hedge.update kf ~y ~x in
        ()
    done ;
    let s = Kalman_hedge.state kf in
      Alcotest.(check bool)
        (Printf.sprintf "β=%g near 2.0" s.beta)
        true
        (abs_float (s.beta -. 2.0) < 0.1)


let test_beta_shifts_tracked () =
  let kf =
    Kalman_hedge.create ~initial_beta:1.0 ~initial_cov:5.0 ~process_var_alpha:1e-7
      ~process_var_beta:5e-3 ~measurement_var:0.25 () in
  let rng = Random.State.make [| 82 |] in
    (* First regime: true β = 2.0 *)
    for _ = 1 to 600 do
      let x = Helpers.normal_sample rng *. 10.0 in
      let y = (2.0 *. x) +. (0.5 *. Helpers.normal_sample rng) in
      let _ = Kalman_hedge.update kf ~y ~x in
        ()
    done ;
    (* Second regime: true β = 3.0 — the filter must track the shift *)
    for _ = 1 to 600 do
      let x = Helpers.normal_sample rng *. 10.0 in
      let y = (3.0 *. x) +. (0.5 *. Helpers.normal_sample rng) in
      let _ = Kalman_hedge.update kf ~y ~x in
        ()
    done ;
    let s = Kalman_hedge.state kf in
      Alcotest.(check bool)
        (Printf.sprintf "β=%g tracked to 3.0" s.beta)
        true
        (abs_float (s.beta -. 3.0) < 0.3)


let test_psd_preserved () =
  let kf = Kalman_hedge.create ~initial_cov:1.0 () in
  let rng = Random.State.make [| 83 |] in
    for _ = 1 to 200 do
      let x = Helpers.normal_sample rng in
      let y = Helpers.normal_sample rng in
      let s = Kalman_hedge.update kf ~y ~x in
        Alcotest.(check bool) "cov diag positive" true (s.cov.(0).(0) >= 0.0 && s.cov.(1).(1) >= 0.0)
    done


let suite =
  [
    Alcotest.test_case "recovers_true_beta" `Quick test_recovers_true_beta;
    Alcotest.test_case "beta_shifts_tracked" `Quick test_beta_shifts_tracked;
    Alcotest.test_case "psd_preserved" `Quick test_psd_preserved;
  ]
