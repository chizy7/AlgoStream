open Algostream_pairs

let signal_t =
  Alcotest.testable
    (fun ppf s -> Format.pp_print_string ppf (Mean_reversion.signal_to_string s))
    ( = )


let test_signal_sequence () =
  let mr = Mean_reversion.create ~entry_z:2.0 ~exit_z:0.5 ~stop_z:4.0 in
    Alcotest.(check signal_t) "hold at z=0" Hold (Mean_reversion.update mr ~z:0.0) ;
    Alcotest.(check signal_t) "enter short at z=2.5" Short_spread (Mean_reversion.update mr ~z:2.5) ;
    Alcotest.(check signal_t) "still short at z=2.0" Hold (Mean_reversion.update mr ~z:2.0) ;
    Alcotest.(check signal_t) "exit short at z=0.3" Exit (Mean_reversion.update mr ~z:0.3) ;
    Alcotest.(check signal_t)
      "enter long at z=-2.5" Long_spread
      (Mean_reversion.update mr ~z:(-2.5)) ;
    Alcotest.(check signal_t) "stop-out long at z=-4.5" Exit (Mean_reversion.update mr ~z:(-4.5))


let test_half_life_phi_half () =
  let r = Helpers.ar1_series ~n:512 ~phi:0.5 ~seed:51 in
    match Mean_reversion.half_life ~residuals:r with
    | Ok hl ->
      Alcotest.(check bool) (Printf.sprintf "half_life=%g near 1.0" hl) true (hl > 0.5 && hl < 2.0)
    | Error _ -> Alcotest.fail "should compute"


let test_half_life_random_walk_non_reverting () =
  let r = Helpers.random_walk_series ~n:512 ~seed:52 in
    match Mean_reversion.half_life ~residuals:r with
    | Ok hl when hl > 50.0 -> () (* very long half-life is acceptable *)
    | Error `Non_reverting -> ()
    | Ok hl -> Alcotest.failf "random walk should be non-reverting; got hl=%g" hl
    | Error _ -> Alcotest.fail "unexpected error"


let test_half_life_too_short () =
  let r = Array.make 4 0.0 in
    match Mean_reversion.half_life ~residuals:r with
    | Error (`Insufficient_data (4, _)) -> ()
    | _ -> Alcotest.fail "expected Insufficient_data"


let suite =
  [
    Alcotest.test_case "signal_sequence" `Quick test_signal_sequence;
    Alcotest.test_case "half_life_phi_half" `Quick test_half_life_phi_half;
    Alcotest.test_case "half_life_random_walk_non_reverting" `Quick
      test_half_life_random_walk_non_reverting;
    Alcotest.test_case "half_life_too_short" `Quick test_half_life_too_short;
  ]
