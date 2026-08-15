module F = Algostream_analytics.Filters

let test_sanity_rejects () =
  Alcotest.(check bool)
    "negative price rejected" true
    (match F.Sanity.check ~price:(-1.0) ~size:1.0 with Reject _ -> true | _ -> false) ;
  Alcotest.(check bool)
    "zero size rejected" true
    (match F.Sanity.check ~price:1.0 ~size:0.0 with Reject _ -> true | _ -> false) ;
  Alcotest.(check bool)
    "nan rejected" true
    (match F.Sanity.check ~price:nan ~size:1.0 with Reject _ -> true | _ -> false) ;
  Alcotest.(check bool)
    "inf rejected" true
    (match F.Sanity.check ~price:infinity ~size:1.0 with Reject _ -> true | _ -> false)


let test_sanity_passes () =
  match F.Sanity.check ~price:50000.0 ~size:0.01 with
  | Ok -> ()
  | Reject _ -> Alcotest.fail "valid input rejected"


let test_ewma_converges_to_constant () =
  let e = F.Ewma.create ~period:20 in
    for _ = 1 to 1000 do
      let _ = F.Ewma.update e 100.0 in
        ()
    done ;
    Alcotest.(check bool) "converges to 100" true (abs_float (F.Ewma.value e -. 100.0) < 1e-6)


let test_ewma_bias_correction () =
  (* fresh EWMA on the first sample should output the first sample, not (alpha * x). *)
  let e = F.Ewma.create ~period:20 in
  let v = F.Ewma.update e 100.0 in
    Alcotest.(check (float 1e-9)) "bias-corrected first sample" 100.0 v


let test_ewma_ready_after_warmup () =
  let e = F.Ewma.create ~period:10 in
    for _ = 1 to 5 do
      let _ = F.Ewma.update e 1.0 in
        ()
    done ;
    Alcotest.(check bool) "not ready early" false (F.Ewma.ready e) ;
    for _ = 1 to 200 do
      let _ = F.Ewma.update e 1.0 in
        ()
    done ;
    Alcotest.(check bool) "ready after enough samples" true (F.Ewma.ready e)


let test_ewma_var_zero_variance_constant () =
  let v = F.Ewma_var.create ~period:20 in
    for _ = 1 to 500 do
      let _ = F.Ewma_var.update v 100.0 in
        ()
    done ;
    Alcotest.(check bool) "variance ~ 0 on constant input" true (F.Ewma_var.value v < 1e-6)


let test_kalman_smooths_noise () =
  let k = F.Kalman1d.create ~signal_to_noise_ratio:0.001 ~warmup:64 in
  let rng_state = Random.State.make [| 42 |] in
  let raw_var = ref 0.0 in
  let smooth_var = ref 0.0 in
  let n = 2000 in
    for i = 1 to n do
      let noise = Random.State.float rng_state 2.0 -. 1.0 in
      let true_signal = 100.0 +. (0.001 *. float_of_int i) in
      let observed = true_signal +. noise in
      let smooth = F.Kalman1d.update k observed in
        raw_var := !raw_var +. (noise *. noise) ;
        if i > 256 then smooth_var := !smooth_var +. ((smooth -. true_signal) ** 2.0)
    done ;
    let smooth_rms = sqrt (!smooth_var /. float_of_int (n - 256)) in
      Alcotest.(check bool) "Kalman reduces noise vs raw 1.0 std-dev" true (smooth_rms < 0.5)


let test_median_window_basic () =
  let m = F.Median_window.create ~window:5 in
  let _ = F.Median_window.update m 1.0 in
  let _ = F.Median_window.update m 5.0 in
  let _ = F.Median_window.update m 3.0 in
  let _ = F.Median_window.update m 4.0 in
  let v = F.Median_window.update m 2.0 in
    Alcotest.(check (float 1e-9)) "median of [1;5;3;4;2] = 3" 3.0 v


let suite =
  [
    Alcotest.test_case "sanity_rejects" `Quick test_sanity_rejects;
    Alcotest.test_case "sanity_passes" `Quick test_sanity_passes;
    Alcotest.test_case "ewma_converges_to_constant" `Quick test_ewma_converges_to_constant;
    Alcotest.test_case "ewma_bias_correction" `Quick test_ewma_bias_correction;
    Alcotest.test_case "ewma_ready_after_warmup" `Quick test_ewma_ready_after_warmup;
    Alcotest.test_case "ewma_var_zero_on_constant" `Quick test_ewma_var_zero_variance_constant;
    Alcotest.test_case "kalman_smooths_noise" `Quick test_kalman_smooths_noise;
    Alcotest.test_case "median_window_basic" `Quick test_median_window_basic;
  ]
