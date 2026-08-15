module Health = Algostream_telemetry.Health

let s = 1_000_000_000L

let test_stale_transitions () =
  let check age =
    Health.stale ~what:"binance" ~age_ns:age ~degraded_after_ns:(Int64.mul 5L s)
      ~failed_after_ns:(Int64.mul 30L s) in
  let is_ok = function Health.Ok -> true | _ -> false in
  let is_degraded = function Health.Degraded _ -> true | _ -> false in
  let is_failed = function Health.Failed _ -> true | _ -> false in
    Alcotest.(check bool) "fresh is ok" true (is_ok (check (Int64.mul 1L s))) ;
    Alcotest.(check bool)
      "just under the warn line is ok" true
      (is_ok (check (Int64.sub (Int64.mul 5L s) 1L))) ;
    Alcotest.(check bool) "at the warn line is degraded" true (is_degraded (check (Int64.mul 5L s))) ;
    Alcotest.(check bool)
      "between the lines is degraded" true
      (is_degraded (check (Int64.mul 20L s))) ;
    Alcotest.(check bool) "at the fail line is failed" true (is_failed (check (Int64.mul 30L s))) ;
    (* Never having received anything is a different problem from being stale, and says so. *)
    match check Int64.max_int with
    | Health.Failed msg ->
      Alcotest.(check bool)
        (Printf.sprintf "no-data message mentions it: %s" msg)
        true
        (String.length msg > 0
        && Option.is_some (String.index_opt msg 'n')
        && not (String.equal msg ""))
    | _ -> Alcotest.fail "no data at all must be Failed"


let test_threshold () =
  let c v =
    Health.threshold ~what:"depth" ~value:v ~degraded_above:100.0 ~failed_above:1000.0 ~unit_:""
  in
    Alcotest.(check bool) "below both" true (match c 10.0 with Health.Ok -> true | _ -> false) ;
    Alcotest.(check bool)
      "above warn" true
      (match c 500.0 with Health.Degraded _ -> true | _ -> false) ;
    Alcotest.(check bool)
      "above fail" true
      (match c 5000.0 with Health.Failed _ -> true | _ -> false)


let test_worst_and_overall () =
  Alcotest.(check int) "empty is ok" 0 (Health.severity_rank (Health.worst [])) ;
  Alcotest.(check int)
    "degraded beats ok" 1
    (Health.severity_rank (Health.worst [ Health.Ok; Health.Degraded "x"; Health.Ok ])) ;
  Alcotest.(check int)
    "failed beats degraded" 2
    (Health.severity_rank (Health.worst [ Health.Degraded "x"; Health.Failed "y" ]))


(* One broken probe must not take down the health endpoint. *)
let test_raising_check_is_contained () =
  let checks =
    [
      { Health.name = "good"; run = (fun () -> Health.Ok) };
      { Health.name = "bad"; run = (fun () -> failwith "probe blew up") };
    ] in
  let reports = Health.run_all checks ~ts_ns:42L in
    Alcotest.(check int) "both reported" 2 (List.length reports) ;
    let bad = List.find (fun (r : Health.report) -> r.Health.check_name = "bad") reports in
      Alcotest.(check bool)
        "raising check reports Failed" true
        (match bad.Health.status with Health.Failed _ -> true | _ -> false) ;
      Alcotest.(check int64) "timestamp stamped" 42L bad.Health.checked_at_ns ;
      Alcotest.(check int) "overall is failed" 2 (Health.severity_rank (Health.overall reports))


let suite =
  [
    Alcotest.test_case "stale_transitions" `Quick test_stale_transitions;
    Alcotest.test_case "threshold" `Quick test_threshold;
    Alcotest.test_case "worst_and_overall" `Quick test_worst_and_overall;
    Alcotest.test_case "raising_check_is_contained" `Quick test_raising_check_is_contained;
  ]
