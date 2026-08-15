module Side = Algostream_strategy.Side
module Order = Algostream_domain_orders.Order

let test_round_trips_through_trade_side () =
  List.iter
    (fun s ->
      Alcotest.(check bool)
        (Printf.sprintf "%s round-trips" (Side.to_string s))
        true
        (Side.equal (Side.of_trade_side (Side.to_trade_side s)) s))
    [ Side.Buy; Side.Sell ]


let test_sign () =
  Alcotest.(check (float 1e-12)) "buy is +1" 1.0 (Side.sign Side.Buy) ;
  Alcotest.(check (float 1e-12)) "sell is -1" (-1.0) (Side.sign Side.Sell)


(* The side argument is authoritative: passing an already-negative quantity for a sell must not
   double-negate into a buy. That is the sign bug this module exists to prevent. *)
let test_signed_treats_quantity_as_a_magnitude () =
  Alcotest.(check (float 1e-12)) "buy 5" 5.0 (Side.signed Side.Buy ~qty:5.0) ;
  Alcotest.(check (float 1e-12)) "sell 5" (-5.0) (Side.signed Side.Sell ~qty:5.0) ;
  Alcotest.(check (float 1e-12))
    "sell -5 is still -5, not +5" (-5.0)
    (Side.signed Side.Sell ~qty:(-5.0)) ;
  Alcotest.(check (float 1e-12)) "buy -5 is +5" 5.0 (Side.signed Side.Buy ~qty:(-5.0))


let test_of_signed () =
  Alcotest.(check bool) "positive is a buy" true (Side.of_signed 3.0 = Some Side.Buy) ;
  Alcotest.(check bool) "negative is a sell" true (Side.of_signed (-3.0) = Some Side.Sell) ;
  Alcotest.(check bool) "zero has no direction" true (Side.of_signed 0.0 = None)


let test_signed_and_of_signed_are_inverse () =
  List.iter
    (fun s ->
      let q = Side.signed s ~qty:7.5 in
        Alcotest.(check bool)
          (Printf.sprintf "%s survives the round trip" (Side.to_string s))
          true
          (Side.of_signed q = Some s))
    [ Side.Buy; Side.Sell ]


let test_opposite () =
  Alcotest.(check bool) "buy flips to sell" true (Side.equal (Side.opposite Side.Buy) Side.Sell) ;
  Alcotest.(check bool)
    "and back" true
    (Side.equal (Side.opposite (Side.opposite Side.Buy)) Side.Buy)


(* Side.t is a re-export of Order.order_side, so the two must be interchangeable without a cast. *)
let test_is_the_same_type_as_order_side () =
  let o : Order.order_side = Side.Buy in
    Alcotest.(check bool) "assignable to Order.order_side" true (o = Order.Buy)


let suite =
  [
    Alcotest.test_case "round_trips_through_trade_side" `Quick test_round_trips_through_trade_side;
    Alcotest.test_case "sign" `Quick test_sign;
    Alcotest.test_case "signed_treats_quantity_as_a_magnitude" `Quick
      test_signed_treats_quantity_as_a_magnitude;
    Alcotest.test_case "of_signed" `Quick test_of_signed;
    Alcotest.test_case "signed_and_of_signed_are_inverse" `Quick
      test_signed_and_of_signed_are_inverse;
    Alcotest.test_case "opposite" `Quick test_opposite;
    Alcotest.test_case "is_the_same_type_as_order_side" `Quick test_is_the_same_type_as_order_side;
  ]
