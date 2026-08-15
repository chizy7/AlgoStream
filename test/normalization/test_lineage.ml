module L = Algostream_normalization.Lineage

let test_round_trip () =
  let parts = L.of_source "binance/normalized/v1" in
    Alcotest.(check int) "3 parts" 3 (List.length parts) ;
    Alcotest.(check string) "round trip" "binance/normalized/v1" (L.to_source parts)


let test_push_valid () =
  match L.push "binance" "normalized" with
  | Some s -> Alcotest.(check string) "appended" "binance/normalized" s
  | None -> Alcotest.fail "expected Some"


let test_push_rejects_uppercase () =
  Alcotest.(check bool) "rejected" true (Option.is_none (L.push "binance" "Normalized"))


let test_push_rejects_dash () =
  Alcotest.(check bool) "rejected" true (Option.is_none (L.push "binance" "x-y"))


let test_push_rejects_overlong () =
  let long = String.make 60 'x' in
    Alcotest.(check bool) "overlong rejected" true (Option.is_none (L.push long "more"))


let test_is_valid () =
  Alcotest.(check bool) "valid" true (L.is_valid "binance/normalized/v1") ;
  Alcotest.(check bool) "empty" false (L.is_valid "") ;
  Alcotest.(check bool) "bad chars" false (L.is_valid "Binance") ;
  Alcotest.(check bool) "trailing slash" false (L.is_valid "binance/")


let suite =
  [
    Alcotest.test_case "round_trip" `Quick test_round_trip;
    Alcotest.test_case "push_valid" `Quick test_push_valid;
    Alcotest.test_case "push_rejects_uppercase" `Quick test_push_rejects_uppercase;
    Alcotest.test_case "push_rejects_dash" `Quick test_push_rejects_dash;
    Alcotest.test_case "push_rejects_overlong" `Quick test_push_rejects_overlong;
    Alcotest.test_case "is_valid" `Quick test_is_valid;
  ]
