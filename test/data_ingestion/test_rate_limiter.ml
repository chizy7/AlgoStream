module RL = Algostream_data_ingestion.Rate_limiter

(* Mock clock — caller advances explicitly. *)
let mock_clock now_ref () = !now_ref

let test_basic_consume () =
  let now = ref 0L in
  let rl = RL.create ~clock_ns:(mock_clock now) ~capacity:5 ~refill_per_sec:5 ~reserved:1 () in
    for _ = 1 to 5 do
      Alcotest.(check bool) "burst ok" true (RL.try_take rl)
    done ;
    Alcotest.(check bool) "denied after burst" false (RL.try_take rl)


let test_refill () =
  let now = ref 0L in
  let rl = RL.create ~clock_ns:(mock_clock now) ~capacity:5 ~refill_per_sec:5 ~reserved:0 () in
    for _ = 1 to 5 do
      ignore (RL.try_take rl : bool)
    done ;
    now := Int64.of_int 1_000_000_000 ;
    (* 1s elapsed → 5 tokens refilled *)
    for _ = 1 to 5 do
      Alcotest.(check bool) "post-refill ok" true (RL.try_take rl)
    done ;
    Alcotest.(check bool) "empty again" false (RL.try_take rl)


let test_reserved_isolated () =
  let now = ref 0L in
  let rl = RL.create ~clock_ns:(mock_clock now) ~capacity:2 ~refill_per_sec:1 ~reserved:1 () in
    (* drain main bucket *)
    Alcotest.(check bool) "main 1" true (RL.try_take rl) ;
    Alcotest.(check bool) "main 2" true (RL.try_take rl) ;
    Alcotest.(check bool) "main empty" false (RL.try_take rl) ;
    (* reserved still has 1 token *)
    Alcotest.(check bool) "reserved consumed" true (RL.try_take ~reserved:true rl) ;
    Alcotest.(check bool) "reserved empty" false (RL.try_take ~reserved:true rl)


let suite =
  [
    Alcotest.test_case "basic_consume" `Quick test_basic_consume;
    Alcotest.test_case "refill" `Quick test_refill;
    Alcotest.test_case "reserved_isolated" `Quick test_reserved_isolated;
  ]
