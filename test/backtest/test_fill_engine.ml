module BT = Algostream_backtest
module Order = Algostream_domain_orders.Order
module Trade = Algostream_domain_trades.Trade
module Rng = Algostream_rng.Rng
module Action = Algostream_strategy.Action
module Event = Algostream_strategy.Event
module Side = Algostream_strategy.Side
open Helpers

let make ?(maker_fill = BT.Fill_engine.Queue_position) ?(slippage = BT.Slippage.Book_walk)
  ?(venue = free_venue) () =
  let cost = BT.Cost_model.create (BT.Cost_model.default_config venue) in
  let cfg =
    {
      BT.Fill_engine.slippage;
      latency = BT.Latency.zero;
      maker_fill;
      stop_trigger = BT.Fill_engine.Trigger_touch;
      allow_partial = true;
    } in
    BT.Fill_engine.create ~config:cfg ~cost ~rng:(Rng.create ~seed:1)


let intent_of = function Action.Submit i -> i | _ -> Alcotest.fail "expected a Submit action"

let ctx_of ?(bid = 99.0) ?(ask = 101.0) ?(last = 100.0) ?book () =
  {
    BT.Slippage.bid = Some bid;
    ask = Some ask;
    last;
    sigma = None;
    adv = None;
    regime = None;
    book;
  }


(* A market buy that walks three ask levels must pay the size-weighted average of those levels.
   Levels: 10 @ 100, 10 @ 101, 10 @ 102. Buying 25 takes 10 + 10 + 5: (10*100 + 10*101 + 5*102) / 25
   = (1000 + 1010 + 510) / 25 = 2520 / 25 = 100.8 *)
let test_market_order_walks_book () =
  let fe = make () in
  let bk =
    match
      book
        ~asks:
          [|
            level ~price:100.0 ~size:10.0;
            level ~price:101.0 ~size:10.0;
            level ~price:102.0 ~size:10.0;
          |]
        ~bids:[| level ~price:99.0 ~size:50.0 |]
        ()
    with
    | BT.Data_source.Book b -> b
    | _ -> assert false in
  let ctx = ctx_of ~book:bk () in
  let i = intent_of (buy ~qty:25.0 ~id:"m1" ()) in
    ignore (BT.Fill_engine.admit fe ~now_ns:0L i ~order_id:"o1" ~decision_price:100.0) ;
    let fills, _ =
      BT.Fill_engine.on_market fe ~now_ns:1L (print_ ~i:0 ~price:100.0 ~size:1.0 ()) ~ctx in
      match fills with
      | [ f ] ->
        Alcotest.(check (float 1e-9)) "avg fill price = 100.8" 100.8 f.Event.price ;
        Alcotest.(check (float 1e-9)) "filled 25" 25.0 f.Event.quantity ;
        Alcotest.(check bool) "taker" true (f.Event.liquidity = Trade.Taker)
      | fs -> Alcotest.failf "expected exactly one fill, got %d" (List.length fs)


(* Book too thin: 25 wanted, only 15 available. The remainder must be reported unfilled. *)
let test_book_exhaustion_reports_unfilled () =
  let fe = make () in
  let bk =
    match
      book
        ~asks:[| level ~price:100.0 ~size:10.0; level ~price:101.0 ~size:5.0 |]
        ~bids:[| level ~price:99.0 ~size:50.0 |]
        ()
    with
    | BT.Data_source.Book b -> b
    | _ -> assert false in
  let ctx = ctx_of ~book:bk () in
  let i = intent_of (buy ~qty:25.0 ~id:"m2" ()) in
    ignore (BT.Fill_engine.admit fe ~now_ns:0L i ~order_id:"o2" ~decision_price:100.0) ;
    let fills, _ =
      BT.Fill_engine.on_market fe ~now_ns:1L (print_ ~i:0 ~price:100.0 ~size:1.0 ()) ~ctx in
      match fills with
      | [ f ] ->
        Alcotest.(check (float 1e-9)) "filled only what the book held" 15.0 f.Event.quantity
      | fs -> Alcotest.failf "expected one partial fill, got %d" (List.length fs)


(* Queue position: a resting buy limit at 99 behind 100 units of depth. A 60-lot print at 99 does
   not reach us; a further 60-lot print spills 20 past the queue and fills 20 of our 30. *)
let test_queue_position_drains_before_filling () =
  let fe = make () in
  let bk =
    match
      book ~bids:[| level ~price:99.0 ~size:100.0 |] ~asks:[| level ~price:101.0 ~size:50.0 |] ()
    with
    | BT.Data_source.Book b -> b
    | _ -> assert false in
  let ctx = ctx_of ~book:bk () in
  let i =
    intent_of (buy ~qty:30.0 ~order_type:(Order.Limit 99.0) ~urgency:Action.Passive ~id:"q1" ())
  in
    ignore (BT.Fill_engine.admit fe ~now_ns:0L i ~order_id:"o3" ~decision_price:100.0) ;
    let f1, _ =
      BT.Fill_engine.on_market fe ~now_ns:1L (print_ ~i:1 ~price:99.0 ~size:60.0 ()) ~ctx in
      Alcotest.(check int) "60 of 100 ahead consumed: no fill yet" 0 (List.length f1) ;
      let f2, _ =
        BT.Fill_engine.on_market fe ~now_ns:2L (print_ ~i:2 ~price:99.0 ~size:60.0 ()) ~ctx in
        match f2 with
        | [ f ] ->
          Alcotest.(check (float 1e-9)) "spill past the queue fills 20" 20.0 f.Event.quantity ;
          Alcotest.(check bool) "maker" true (f.Event.liquidity = Trade.Maker) ;
          Alcotest.(check (float 1e-9)) "at the limit price" 99.0 f.Event.price
        | fs -> Alcotest.failf "expected one fill, got %d" (List.length fs)


(* Optimistic maker fills the moment the price is touched — the upper bound, for contrast. *)
let test_optimistic_maker_fills_immediately () =
  let fe = make ~maker_fill:BT.Fill_engine.Optimistic () in
  let bk =
    match
      book ~bids:[| level ~price:99.0 ~size:100.0 |] ~asks:[| level ~price:101.0 ~size:50.0 |] ()
    with
    | BT.Data_source.Book b -> b
    | _ -> assert false in
  let ctx = ctx_of ~book:bk () in
  let i =
    intent_of (buy ~qty:30.0 ~order_type:(Order.Limit 99.0) ~urgency:Action.Passive ~id:"q2" ())
  in
    ignore (BT.Fill_engine.admit fe ~now_ns:0L i ~order_id:"o4" ~decision_price:100.0) ;
    let fills, _ =
      BT.Fill_engine.on_market fe ~now_ns:1L (print_ ~i:1 ~price:99.0 ~size:1.0 ()) ~ctx in
      Alcotest.(check int) "fills without draining the queue" 1 (List.length fills)


(* Fill-or-kill against a book that cannot fill it must produce zero fills and a cancellation. *)
let test_fok_kills_on_insufficient_depth () =
  let fe = make () in
  let bk =
    match
      book ~asks:[| level ~price:100.0 ~size:5.0 |] ~bids:[| level ~price:99.0 ~size:50.0 |] ()
    with
    | BT.Data_source.Book b -> b
    | _ -> assert false in
  let ctx = ctx_of ~book:bk () in
  let i = intent_of (buy ~qty:25.0 ~tif:Order.Fill_or_kill ~id:"fok" ()) in
    ignore (BT.Fill_engine.admit fe ~now_ns:0L i ~order_id:"o5" ~decision_price:100.0) ;
    let fills, _ =
      BT.Fill_engine.on_market fe ~now_ns:1L (print_ ~i:0 ~price:100.0 ~size:1.0 ()) ~ctx in
    let s = BT.Fill_engine.stats fe in
      Alcotest.(check int) "no fills" 0 (List.length fills) ;
      Alcotest.(check int) "one FOK kill" 1 s.BT.Fill_engine.n_fok_killed ;
      Alcotest.(check bool)
        "no longer working" false
        (BT.Fill_engine.is_working fe ~client_order_id:"fok")


(* IOC fills what it can and cancels the rest. *)
let test_ioc_cancels_remainder () =
  let fe = make () in
  let bk =
    match
      book ~asks:[| level ~price:100.0 ~size:5.0 |] ~bids:[| level ~price:99.0 ~size:50.0 |] ()
    with
    | BT.Data_source.Book b -> b
    | _ -> assert false in
  let ctx = ctx_of ~book:bk () in
  let i = intent_of (buy ~qty:25.0 ~tif:Order.Immediate_or_cancel ~id:"ioc" ()) in
    ignore (BT.Fill_engine.admit fe ~now_ns:0L i ~order_id:"o6" ~decision_price:100.0) ;
    let fills, _ =
      BT.Fill_engine.on_market fe ~now_ns:1L (print_ ~i:0 ~price:100.0 ~size:1.0 ()) ~ctx in
    let s = BT.Fill_engine.stats fe in
      Alcotest.(check int) "one partial fill" 1 (List.length fills) ;
      Alcotest.(check int) "remainder cancelled" 1 s.BT.Fill_engine.n_ioc_remainder_cancelled ;
      Alcotest.(check bool)
        "no longer working" false
        (BT.Fill_engine.is_working fe ~client_order_id:"ioc")


(* A buy-stop at 105 must not trigger while the ask is 101, and must trigger once it reaches 105. *)
let test_stop_triggers_on_touch () =
  let fe = make ~slippage:(BT.Slippage.Fixed_bps 0.0) () in
  let i = intent_of (buy ~qty:1.0 ~order_type:(Order.Stop 105.0) ~id:"stp" ()) in
    ignore (BT.Fill_engine.admit fe ~now_ns:0L i ~order_id:"o7" ~decision_price:100.0) ;
    let f1, _ =
      BT.Fill_engine.on_market fe ~now_ns:1L
        (print_ ~i:1 ~price:100.0 ~size:1.0 ())
        ~ctx:(ctx_of ~bid:99.0 ~ask:101.0 ~last:100.0 ()) in
      Alcotest.(check int) "below the stop: no fill" 0 (List.length f1) ;
      let f2, _ =
        BT.Fill_engine.on_market fe ~now_ns:2L
          (print_ ~i:2 ~price:105.0 ~size:1.0 ())
          ~ctx:(ctx_of ~bid:104.0 ~ask:105.5 ~last:105.0 ()) in
        Alcotest.(check int) "stop fires and fills" 1 (List.length f2) ;
        Alcotest.(check int) "counted" 1 (BT.Fill_engine.stats fe).BT.Fill_engine.n_stops_triggered


(* Good-till-date must expire when event time passes it. *)
let test_gtd_expires () =
  let fe = make () in
  let expiry = Algostream_domain_common.Timestamp.of_ns 5_000_000_000L in
  let i =
    intent_of
      (buy ~qty:1.0 ~order_type:(Order.Limit 1.0) ~tif:(Order.Good_till_date expiry) ~id:"gtd" ())
  in
    ignore (BT.Fill_engine.admit fe ~now_ns:0L i ~order_id:"o8" ~decision_price:100.0) ;
    let _ =
      BT.Fill_engine.on_market fe ~now_ns:1_000_000_000L
        (print_ ~i:1 ~price:100.0 ~size:1.0 ())
        ~ctx:(ctx_of ()) in
      Alcotest.(check bool)
        "still working before expiry" true
        (BT.Fill_engine.is_working fe ~client_order_id:"gtd") ;
      let _ =
        BT.Fill_engine.on_market fe ~now_ns:6_000_000_000L
          (print_ ~i:6 ~price:100.0 ~size:1.0 ())
          ~ctx:(ctx_of ()) in
        Alcotest.(check int) "expired" 1 (BT.Fill_engine.stats fe).BT.Fill_engine.n_expired ;
        Alcotest.(check bool)
          "no longer working" false
          (BT.Fill_engine.is_working fe ~client_order_id:"gtd")


(* Maker and taker must be charged different fees — proving liquidity flows into the cost model. *)
let test_maker_taker_fees_differ () =
  let venue = fee_venue ~maker_bps:1.0 ~taker_bps:10.0 in
  let bk =
    match
      book ~bids:[| level ~price:99.0 ~size:0.0 |] ~asks:[| level ~price:100.0 ~size:100.0 |] ()
    with
    | BT.Data_source.Book b -> b
    | _ -> assert false in
  let ctx = ctx_of ~book:bk () in
  (* Taker: crosses immediately. *)
  let fe_t = make ~venue () in
  let it = intent_of (buy ~qty:10.0 ~id:"t" ()) in
    ignore (BT.Fill_engine.admit fe_t ~now_ns:0L it ~order_id:"ot" ~decision_price:100.0) ;
    let ft, _ =
      BT.Fill_engine.on_market fe_t ~now_ns:1L (print_ ~i:0 ~price:100.0 ~size:1.0 ()) ~ctx in
    (* Maker: rests at 99 with no queue ahead, filled by a print through it. *)
    let fe_m = make ~venue () in
    let im =
      intent_of (buy ~qty:10.0 ~order_type:(Order.Limit 99.0) ~urgency:Action.Passive ~id:"m" ())
    in
      ignore (BT.Fill_engine.admit fe_m ~now_ns:0L im ~order_id:"om" ~decision_price:100.0) ;
      let fm, _ =
        BT.Fill_engine.on_market fe_m ~now_ns:1L (print_ ~i:1 ~price:99.0 ~size:20.0 ()) ~ctx in
        match (ft, fm) with
        | [ t ], [ m ] ->
          (* 10 units @ 100 = 1000 notional. Taker 10bps = 1.0; maker 1bps at 99 = 0.099. *)
          Alcotest.(check (float 1e-9)) "taker fee" 1.0 t.Event.commission ;
          Alcotest.(check (float 1e-9)) "maker fee" 0.099 m.Event.commission ;
          Alcotest.(check bool) "maker is cheaper" true (m.Event.commission < t.Event.commission)
        | _ -> Alcotest.fail "expected one fill on each engine"


let suite =
  [
    Alcotest.test_case "market_order_walks_book" `Quick test_market_order_walks_book;
    Alcotest.test_case "book_exhaustion_reports_unfilled" `Quick
      test_book_exhaustion_reports_unfilled;
    Alcotest.test_case "queue_position_drains_before_filling" `Quick
      test_queue_position_drains_before_filling;
    Alcotest.test_case "optimistic_maker_fills_immediately" `Quick
      test_optimistic_maker_fills_immediately;
    Alcotest.test_case "fok_kills_on_insufficient_depth" `Quick test_fok_kills_on_insufficient_depth;
    Alcotest.test_case "ioc_cancels_remainder" `Quick test_ioc_cancels_remainder;
    Alcotest.test_case "stop_triggers_on_touch" `Quick test_stop_triggers_on_touch;
    Alcotest.test_case "gtd_expires" `Quick test_gtd_expires;
    Alcotest.test_case "maker_taker_fees_differ" `Quick test_maker_taker_fees_differ;
  ]
