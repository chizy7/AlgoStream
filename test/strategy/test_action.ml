module Action = Algostream_strategy.Action
module Side = Algostream_strategy.Side
module Order = Algostream_domain_orders.Order

let mk ?(qty = 1.0) ?(order_type = Order.Market) () =
  Action.submit ~symbol:"BTC" ~side:Side.Buy ~quantity:qty ~order_type ~client_order_id:"c1"
    ~strategy_id:"s1" ()


let test_submit_defaults () =
  match mk () with
  | Action.Submit i ->
    Alcotest.(check string) "symbol" "BTC" i.Action.symbol ;
    Alcotest.(check bool)
      "defaults to good-till-cancel" true
      (i.Action.time_in_force = Order.Good_till_cancel) ;
    Alcotest.(check bool) "defaults to normal urgency" true (i.Action.urgency = Action.Normal) ;
    Alcotest.(check string) "empty tag" "" i.Action.tag
  | _ -> Alcotest.fail "expected a Submit"


(* A zero-size order is always a sizing bug upstream; failing loudly beats emitting something the
   fill engine will silently ignore. *)
let test_non_positive_quantity_raises () =
  Alcotest.(check bool)
    "zero quantity raises" true
    (try
       ignore (mk ~qty:0.0 ()) ;
       false
     with Invalid_argument _ -> true) ;
  Alcotest.(check bool)
    "negative quantity raises" true
    (try
       ignore (mk ~qty:(-1.0) ()) ;
       false
     with Invalid_argument _ -> true)


let test_overrides_are_carried_through () =
  let a =
    Action.submit ~symbol:"ETH" ~side:Side.Sell ~quantity:2.0 ~order_type:(Order.Limit 99.0)
      ~time_in_force:Order.Immediate_or_cancel ~urgency:Action.Passive ~tag:"entry"
      ~client_order_id:"c2" ~strategy_id:"s2" () in
    match a with
    | Action.Submit i ->
      Alcotest.(check bool) "IOC" true (i.Action.time_in_force = Order.Immediate_or_cancel) ;
      Alcotest.(check bool) "passive" true (i.Action.urgency = Action.Passive) ;
      Alcotest.(check string) "tag" "entry" i.Action.tag ;
      Alcotest.(check bool) "limit price" true (i.Action.order_type = Order.Limit 99.0)
    | _ -> Alcotest.fail "expected a Submit"


let test_to_string_covers_every_constructor () =
  let cases =
    [
      mk ();
      Action.Cancel "c1";
      Action.Replace { client_order_id = "c1"; new_quantity = Some 2.0; new_price = None };
      Action.Set_timer { ts_ns = 5L; tag = "t" };
      Action.Log "hello";
    ] in
    List.iter
      (fun a ->
        let s = Action.to_string a in
          Alcotest.(check bool) "produces a non-empty description" true (String.length s > 0))
      cases


let suite =
  [
    Alcotest.test_case "submit_defaults" `Quick test_submit_defaults;
    Alcotest.test_case "non_positive_quantity_raises" `Quick test_non_positive_quantity_raises;
    Alcotest.test_case "overrides_are_carried_through" `Quick test_overrides_are_carried_through;
    Alcotest.test_case "to_string_covers_every_constructor" `Quick
      test_to_string_covers_every_constructor;
  ]
