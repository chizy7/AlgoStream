open Algostream_pairs

let test_random_walk_non_stationary () =
  let s = Helpers.random_walk_series ~n:512 ~seed:42 in
    match Adf.test ~variant:Adf.With_constant ~lag:1 s with
    | Error _ -> Alcotest.fail "adf insufficient data"
    | Ok r ->
      (* Random walk: ADF should fail to reject the unit-root null. p ≥ 0.05 in the limit. *)
      Alcotest.(check bool)
        (Printf.sprintf "random walk p=%g should not strongly reject" r.p_value)
        true (r.p_value > 0.05)


let test_stationary_ar1_phi_half () =
  let s = Helpers.ar1_series ~n:512 ~phi:0.5 ~seed:43 in
    match Adf.test ~variant:Adf.With_constant ~lag:1 s with
    | Error _ -> Alcotest.fail "adf insufficient data"
    | Ok r ->
      Alcotest.(check bool)
        (Printf.sprintf "AR(1) phi=0.5 p=%g should reject" r.p_value)
        true (r.p_value < 0.05)


let test_stationary_ar1_phi_high () =
  (* phi=0.95 is borderline; should still reject (large n). *)
  let s = Helpers.ar1_series ~n:1024 ~phi:0.95 ~seed:44 in
    match Adf.test ~variant:Adf.With_constant ~lag:1 s with
    | Error _ -> Alcotest.fail "adf insufficient data"
    | Ok r ->
      Alcotest.(check bool)
        (Printf.sprintf "AR(1) phi=0.95 t=%g should be negative" r.t_stat)
        true (r.t_stat < 0.0)


let test_schwert_lag_bounds () =
  Alcotest.(check int) "lag at n=0 is 1" 1 (Adf.schwert_lag ~n:0) ;
  Alcotest.(check bool)
    "lag at n=100 in [1,4]" true
    (let l = Adf.schwert_lag ~n:100 in
       l >= 1 && l <= 4) ;
  Alcotest.(check bool) "lag at n=10000 capped at 4" true (Adf.schwert_lag ~n:10000 <= 4)


let suite =
  [
    Alcotest.test_case "random_walk_non_stationary" `Quick test_random_walk_non_stationary;
    Alcotest.test_case "stationary_ar1_phi_half" `Quick test_stationary_ar1_phi_half;
    Alcotest.test_case "stationary_ar1_phi_high" `Quick test_stationary_ar1_phi_high;
    Alcotest.test_case "schwert_lag_bounds" `Quick test_schwert_lag_bounds;
  ]
