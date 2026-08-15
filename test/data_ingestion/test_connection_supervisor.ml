module CS = Algostream_data_ingestion.Connection_supervisor
module Cfg = Algostream_common_config.Exchange_config
module EB = Algostream_infrastructure_event_bus
module Event_bus = EB.Event_bus

let make_supervisor ?(threshold = 3) ?(circuit_open_ms = 100) () =
  let bus = Event_bus.create () in
  let cfg =
    {
      (Cfg.binance_default ~symbols:[ "BTCUSDT" ]) with
      retry =
        {
          Cfg.default_retry with
          base_backoff_ms = 1;
          max_backoff_ms = 10;
          jitter_pct = 0.0;
          circuit_breaker_threshold = threshold;
          circuit_open_ms;
        };
    } in
    (CS.create ~config:cfg ~bus (), bus)


let test_initial_state () =
  let s, _bus = make_supervisor () in
    match CS.current_state s with
    | Connecting -> ()
    | _ -> Alcotest.fail "expected initial Connecting"


let test_connected_resets_failures () =
  let s, _bus = make_supervisor () in
    CS.note_failure s ~reason:"boom" () ;
    Alcotest.(check int) "1 failure" 1 (CS.consecutive_failures s) ;
    CS.note_connected s ;
    Alcotest.(check int) "reset on connect" 0 (CS.consecutive_failures s)


let test_circuit_opens_after_threshold () =
  let s, _bus = make_supervisor ~threshold:3 () in
    CS.note_failure s ~reason:"a" () ;
    CS.note_failure s ~reason:"b" () ;
    (match CS.current_state s with
    | Reconnecting _ -> ()
    | _ -> Alcotest.fail "expected Reconnecting after 2 failures") ;
    CS.note_failure s ~reason:"c" () ;
    match CS.current_state s with
    | Open_circuit _ -> ()
    | _ -> Alcotest.fail "expected Open_circuit after 3 failures"


let test_circuit_recovers () =
  let s, _bus = make_supervisor ~threshold:2 ~circuit_open_ms:1 () in
    CS.note_failure s ~reason:"a" () ;
    CS.note_failure s ~reason:"b" () ;
    (* sleep 5ms to let circuit_open_ms (1ms) elapse *)
    Unix.sleepf 0.005 ;
    Alcotest.(check bool) "ready after circuit elapse" true (CS.poll_ready_to_attempt s)


let suite =
  [
    Alcotest.test_case "initial_state" `Quick test_initial_state;
    Alcotest.test_case "connected_resets_failures" `Quick test_connected_resets_failures;
    Alcotest.test_case "circuit_opens_after_threshold" `Quick test_circuit_opens_after_threshold;
    Alcotest.test_case "circuit_recovers" `Quick test_circuit_recovers;
  ]
