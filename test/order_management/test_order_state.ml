open Algostream_order_management
module Order = Algostream_domain_orders.Order

let order_with_status status =
  let o = Helpers.make_order () in
    { o with status }


let test_is_terminal () =
  Alcotest.(check bool) "Pending not terminal" false (Order_state.is_terminal Order.Pending) ;
  Alcotest.(check bool) "Open not terminal" false (Order_state.is_terminal Order.Open) ;
  Alcotest.(check bool)
    "Partially_filled not terminal" false
    (Order_state.is_terminal (Order.Partially_filled { filled_quantity = 1.0 })) ;
  Alcotest.(check bool) "Filled terminal" true (Order_state.is_terminal Order.Filled) ;
  Alcotest.(check bool) "Cancelled terminal" true (Order_state.is_terminal Order.Cancelled) ;
  Alcotest.(check bool) "Rejected terminal" true (Order_state.is_terminal (Order.Rejected "test")) ;
  Alcotest.(check bool) "Expired terminal" true (Order_state.is_terminal Order.Expired)


let test_is_active () =
  Alcotest.(check bool)
    "Pending not active (no fill possible yet)" false
    (Order_state.is_active Order.Pending) ;
  Alcotest.(check bool) "Open active" true (Order_state.is_active Order.Open) ;
  Alcotest.(check bool)
    "Partially_filled active" true
    (Order_state.is_active (Order.Partially_filled { filled_quantity = 1.0 })) ;
  Alcotest.(check bool) "Filled not active" false (Order_state.is_active Order.Filled)


let test_pending_transitions () =
  Alcotest.(check bool)
    "Pending → Open" true
    (Order_state.can_transition ~from_:Order.Pending ~to_:Order.Open) ;
  Alcotest.(check bool)
    "Pending → Cancelled" true
    (Order_state.can_transition ~from_:Order.Pending ~to_:Order.Cancelled) ;
  Alcotest.(check bool)
    "Pending → Rejected" true
    (Order_state.can_transition ~from_:Order.Pending ~to_:Order.(Rejected "no")) ;
  Alcotest.(check bool)
    "Pending → Filled (illegal)" false
    (Order_state.can_transition ~from_:Order.Pending ~to_:Order.Filled)


let test_terminal_blocks_transition () =
  let o = order_with_status Order.Filled in
    match Order_state.transition o ~to_:Order.Open with
    | Error (Terminal_state "Filled") -> ()
    | Ok _ -> Alcotest.fail "should not transition out of terminal"
    | Error _ -> Alcotest.fail "expected Terminal_state error"


let test_invalid_transition_errors () =
  let o = order_with_status Order.Pending in
    match Order_state.transition o ~to_:Order.Filled with
    | Error (Invalid_transition { from_ = "Pending"; to_ = "Filled" }) -> ()
    | Ok _ -> Alcotest.fail "should reject Pending → Filled"
    | Error _ -> Alcotest.fail "expected Invalid_transition"


let test_valid_transition_returns_ok () =
  let o = order_with_status Order.Open in
    match Order_state.transition o ~to_:Order.Filled with
    | Ok Order.Filled -> ()
    | Ok _ -> Alcotest.fail "unexpected status"
    | Error _ -> Alcotest.fail "should succeed"


let suite =
  [
    Alcotest.test_case "is_terminal" `Quick test_is_terminal;
    Alcotest.test_case "is_active" `Quick test_is_active;
    Alcotest.test_case "pending_transitions" `Quick test_pending_transitions;
    Alcotest.test_case "terminal_blocks_transition" `Quick test_terminal_blocks_transition;
    Alcotest.test_case "invalid_transition_errors" `Quick test_invalid_transition_errors;
    Alcotest.test_case "valid_transition_returns_ok" `Quick test_valid_transition_returns_ok;
  ]
