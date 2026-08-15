open Algostream_pairs

let test_cointegrated_recovers_beta () =
  let y, x = Helpers.cointegrated_series ~n:512 ~beta:2.0 ~phi_noise:0.3 ~seed_x:44 ~seed_noise:45 in
    match Cointegration.Engle_granger.test ~y ~x () with
    | Error _ -> Alcotest.fail "EG insufficient data"
    | Ok r ->
      Alcotest.(check bool)
        (Printf.sprintf "cointegrated; got coint=%b p=%g beta=%g" r.cointegrated
           r.residual_adf.p_value r.beta)
        true r.cointegrated ;
      Alcotest.(check (float 0.3)) "beta near 2.0" 2.0 r.beta


let test_independent_walks_not_cointegrated () =
  let n = 512 in
  let rng_x = Random.State.make [| 46 |] in
  let rng_y = Random.State.make [| 47 |] in
  let x = Array.make n 0.0 in
  let y = Array.make n 0.0 in
    for i = 1 to n - 1 do
      x.(i) <- x.(i - 1) +. Helpers.normal_sample rng_x ;
      y.(i) <- y.(i - 1) +. Helpers.normal_sample rng_y
    done ;
    match Cointegration.Engle_granger.test ~y ~x () with
    | Error _ -> Alcotest.fail "EG insufficient data"
    | Ok r ->
      Alcotest.(check bool)
        (Printf.sprintf "independent walks not cointegrated; p=%g" r.residual_adf.p_value)
        false r.cointegrated


let test_length_mismatch () =
  let y = [| 1.0; 2.0; 3.0 |] in
  let x = [| 1.0; 2.0 |] in
    match Cointegration.Engle_granger.test ~y ~x () with
    | Error `Length_mismatch -> ()
    | _ -> Alcotest.fail "expected Length_mismatch"


let suite =
  [
    Alcotest.test_case "cointegrated_recovers_beta" `Quick test_cointegrated_recovers_beta;
    Alcotest.test_case "independent_walks_not_cointegrated" `Quick
      test_independent_walks_not_cointegrated;
    Alcotest.test_case "length_mismatch" `Quick test_length_mismatch;
  ]
