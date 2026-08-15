module PQ = Algostream_infrastructure_event_bus.Priority_queue
module Priority = Algostream_infrastructure_event_bus.Event_types.Priority

let test_empty_pop () =
  let pq = PQ.create ~capacity_per_band:8 ~dummy:0 in
    Alcotest.(check bool) "is_empty" true (PQ.is_empty pq) ;
    Alcotest.(check int) "size" 0 (PQ.size pq) ;
    Alcotest.(check bool) "pop returns None" true (PQ.try_pop pq = None)


let test_push_pop_single_band () =
  let pq = PQ.create ~capacity_per_band:8 ~dummy:0 in
  let _ = PQ.try_push pq Priority.Normal 42 in
  let _ = PQ.try_push pq Priority.Normal 43 in
    Alcotest.(check int) "size" 2 (PQ.size pq) ;
    (match PQ.try_pop pq with
    | Some (v, p) ->
      Alcotest.(check int) "first value" 42 v ;
      Alcotest.(check string) "first priority" "normal" (Priority.to_string p)
    | None -> Alcotest.fail "expected Some") ;
    (match PQ.try_pop pq with
    | Some (v, _) -> Alcotest.(check int) "second value" 43 v
    | None -> Alcotest.fail "expected Some") ;
    Alcotest.(check bool) "drained" true (PQ.is_empty pq)


let test_strict_priority_ordering () =
  let pq = PQ.create ~capacity_per_band:8 ~dummy:0 in
  let _ = PQ.try_push pq Priority.Low 100 in
  let _ = PQ.try_push pq Priority.Normal 200 in
  let _ = PQ.try_push pq Priority.High 300 in
  let _ = PQ.try_push pq Priority.Critical 400 in
  (* Strict priority: Critical → High → Normal → Low *)
  let actual = ref [] in
    while not (PQ.is_empty pq) do
      match PQ.try_pop pq with Some (v, _) -> actual := v :: !actual | None -> ()
    done ;
    Alcotest.(check (list int)) "ordering" [ 400; 300; 200; 100 ] (List.rev !actual)


let test_capacity_overflow () =
  (* RingBuffer rounds capacity to a power of 2 and reserves one slot for the empty/full
     distinction, so [capacity_per_band:4] yields 3 usable slots. *)
  let pq = PQ.create ~capacity_per_band:4 ~dummy:0 in
  let r1 = PQ.try_push pq Priority.Normal 1 in
  let r2 = PQ.try_push pq Priority.Normal 2 in
  let r3 = PQ.try_push pq Priority.Normal 3 in
  let r4 = PQ.try_push pq Priority.Normal 4 in
    Alcotest.(check bool) "first push succeeds" true r1 ;
    Alcotest.(check bool) "second push succeeds" true r2 ;
    Alcotest.(check bool) "third push succeeds" true r3 ;
    Alcotest.(check bool) "overflow returns false" false r4 ;
    (* Other bands should still be free. *)
    Alcotest.(check bool) "different band still free" true (PQ.try_push pq Priority.High 99)


let test_depth_per_band () =
  let pq = PQ.create ~capacity_per_band:8 ~dummy:0 in
  let _ = PQ.try_push pq Priority.Critical 1 in
  let _ = PQ.try_push pq Priority.Critical 2 in
  let _ = PQ.try_push pq Priority.Low 3 in
  let depths = PQ.depth_per_band pq in
    Alcotest.(check int) "critical depth" 2 depths.(0) ;
    Alcotest.(check int) "high depth" 0 depths.(1) ;
    Alcotest.(check int) "normal depth" 0 depths.(2) ;
    Alcotest.(check int) "low depth" 1 depths.(3)


let suite =
  [
    Alcotest.test_case "empty_pop" `Quick test_empty_pop;
    Alcotest.test_case "push_pop_single_band" `Quick test_push_pop_single_band;
    Alcotest.test_case "strict_priority_ordering" `Quick test_strict_priority_ordering;
    Alcotest.test_case "capacity_overflow" `Quick test_capacity_overflow;
    Alcotest.test_case "depth_per_band" `Quick test_depth_per_band;
  ]
