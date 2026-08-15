open Algostream_pairs

let test_regress2_known_answer () =
  let n = 100 in
  let rng = Random.State.make [| 11 |] in
  let x = Array.init n (fun i -> float_of_int i *. 0.1) in
  let y = Array.init n (fun i -> 2.0 +. (3.0 *. x.(i)) +. (0.01 *. Helpers.normal_sample rng)) in
    match Ols.regress2 ~x ~y with
    | Ok (a, b, r2) ->
      Alcotest.(check (float 0.05)) "intercept ~ 2" 2.0 a ;
      Alcotest.(check (float 0.05)) "slope ~ 3" 3.0 b ;
      Alcotest.(check bool) "r2 > 0.99" true (r2 > 0.99)
    | Error _ -> Alcotest.fail "regress2 should succeed"


let test_underdetermined () =
  let x = [| [| 1.0; 2.0 |] |] in
  let y = [| 3.0 |] in
    match Ols.solve ~x ~y ~p:2 with
    | Error (`Underdetermined (1, 2)) -> ()
    | Ok _ -> Alcotest.fail "expected Underdetermined"
    | Error _ -> Alcotest.fail "wrong error"


let test_zero_dim () =
  let x = Array.make 0 [||] in
  let y = Array.make 0 0.0 in
    match Ols.solve ~x ~y ~p:1 with
    | Error (`Underdetermined (0, 1)) -> ()
    | _ -> Alcotest.fail "expected Underdetermined"


let suite =
  [
    Alcotest.test_case "regress2_known_answer" `Quick test_regress2_known_answer;
    Alcotest.test_case "underdetermined" `Quick test_underdetermined;
    Alcotest.test_case "zero_dim" `Quick test_zero_dim;
  ]
