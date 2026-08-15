module Alert = Algostream_telemetry.Alert

let s = 1_000_000_000L

(* The point of the registry: a condition that re-evaluates four times a second must notify once,
   not four times a second. *)
let test_dedup_within_window () =
  let r = Alert.create ~window_ns:(Int64.mul 30L s) () in
  let raise_at ts =
    Alert.raise_alert r ~ts_ns:ts ~code:"FEED_STALE" ~severity:Alert.Warning ~message:"quiet" in
    Alcotest.(check bool) "first raise notifies" true (raise_at 0L) ;
    Alcotest.(check bool) "1s later is suppressed" false (raise_at (Int64.mul 1L s)) ;
    Alcotest.(check bool) "29s later still suppressed" false (raise_at (Int64.mul 29L s)) ;
    Alcotest.(check bool) "30s later notifies again" true (raise_at (Int64.mul 30L s)) ;
    Alcotest.(check int) "still a single active alert" 1 (Alert.count r) ;
    match Alert.active r with
    | [ a ] ->
      Alcotest.(check int) "every raise counted" 4 a.Alert.count ;
      Alcotest.(check int64)
        "last_raised tracks the newest" (Int64.mul 30L s) a.Alert.last_raised_ns ;
      (* The burst restarted, so first_raised moves with it — otherwise the UI would show an
         ever-growing age that says nothing about now. *)
      Alcotest.(check int64)
        "first_raised restarts on re-notify" (Int64.mul 30L s) a.Alert.first_raised_ns
    | xs -> Alcotest.failf "expected exactly one alert, got %d" (List.length xs)


let test_distinct_codes_are_independent () =
  let r = Alert.create () in
    ignore (Alert.raise_alert r ~ts_ns:0L ~code:"A" ~severity:Alert.Info ~message:"a" : bool) ;
    ignore (Alert.raise_alert r ~ts_ns:0L ~code:"B" ~severity:Alert.Critical ~message:"b" : bool) ;
    Alcotest.(check int) "two alerts" 2 (Alert.count r) ;
    (* Sorted most severe first. *)
    match Alert.active r with
    | a :: _ -> Alcotest.(check string) "critical sorts first" "B" a.Alert.code
    | [] -> Alcotest.fail "expected alerts"


let test_clear () =
  let r = Alert.create () in
    ignore (Alert.raise_alert r ~ts_ns:0L ~code:"X" ~severity:Alert.Warning ~message:"x" : bool) ;
    Alcotest.(check bool) "clear reports it was active" true (Alert.clear r ~code:"X") ;
    Alcotest.(check int) "gone" 0 (Alert.count r) ;
    Alcotest.(check bool) "clearing again is a no-op" false (Alert.clear r ~code:"X") ;
    (* Cleared then re-raised is a fresh alert, not a continuation. *)
    Alcotest.(check bool)
      "re-raise after clear notifies" true
      (Alert.raise_alert r ~ts_ns:(Int64.mul 1L s) ~code:"X" ~severity:Alert.Warning ~message:"x")


let test_severity_filter () =
  let r = Alert.create () in
    ignore (Alert.raise_alert r ~ts_ns:0L ~code:"I" ~severity:Alert.Info ~message:"i" : bool) ;
    ignore (Alert.raise_alert r ~ts_ns:0L ~code:"W" ~severity:Alert.Warning ~message:"w" : bool) ;
    ignore (Alert.raise_alert r ~ts_ns:0L ~code:"C" ~severity:Alert.Critical ~message:"c" : bool) ;
    Alcotest.(check int) "at least warning" 2 (List.length (Alert.active_at_least r Alert.Warning)) ;
    Alcotest.(check int)
      "at least critical" 1
      (List.length (Alert.active_at_least r Alert.Critical)) ;
    Alcotest.(check int) "at least info" 3 (List.length (Alert.active_at_least r Alert.Info))


(* The registry is published as one immutable list via CAS, so concurrent raisers must not lose
   updates. *)
let test_concurrent_raises () =
  let r = Alert.create ~window_ns:0L () in
  let n_domains = 4 and per_domain = 2000 in
  let worker k () =
    for i = 1 to per_domain do
      ignore
        (Alert.raise_alert r ~ts_ns:(Int64.of_int i) ~code:(Printf.sprintf "CODE_%d" k)
           ~severity:Alert.Info ~message:"m"
          : bool)
    done in
  let domains = Array.init (n_domains - 1) (fun k -> Domain.spawn (worker (k + 1))) in
    worker 0 () ;
    Array.iter Domain.join domains ;
    Alcotest.(check int) "one alert per code" n_domains (Alert.count r) ;
    List.iter
      (fun (a : Alert.t) ->
        Alcotest.(check int)
          (Printf.sprintf "%s counted every raise" a.Alert.code)
          per_domain a.Alert.count)
      (Alert.active r)


let suite =
  [
    Alcotest.test_case "dedup_within_window" `Quick test_dedup_within_window;
    Alcotest.test_case "distinct_codes_are_independent" `Quick test_distinct_codes_are_independent;
    Alcotest.test_case "clear" `Quick test_clear;
    Alcotest.test_case "severity_filter" `Quick test_severity_filter;
    Alcotest.test_case "concurrent_raises" `Quick test_concurrent_raises;
  ]
