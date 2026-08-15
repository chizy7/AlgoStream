(** {!Affinity} has to be honest on both platforms this project builds on, and the two say different
    things — so the assertions are written against [available] rather than against a hardcoded
    expectation of the host. On Linux pinning is real and a bad core index must be refused by the
    kernel; everywhere else every call must come back [`Unsupported] without pretending.

    The property that matters most: nothing here may report a success it did not achieve.
    [Benchmark.CPUOptimization.isolate_cpu] used to print a message and return [Ok ()] on every
    platform. *)

module Affinity = Algostream_common_utils.Affinity
module Benchmark = Algostream_common_utils.Benchmark

let cpu_count_is_real () =
  Alcotest.(check bool) "at least one core" true (Affinity.cpu_count >= 1) ;
  (* The old hardcoded answer was 4 on every machine. A machine really can have 4, so this asserts
     the weaker but still meaningful property: the value is a plausible core count, not a constant
     that happens to look like one. *)
  Alcotest.(check bool) "not an absurd core count" true (Affinity.cpu_count <= 4096)


let pin_never_raises () =
  List.iter
    (fun core -> match Affinity.pin core with Ok () | Error _ -> ())
    [ 0; 1; -1; Affinity.cpu_count; Affinity.cpu_count + 1000; max_int ]


let unsupported_platforms_say_so () =
  if Affinity.available then Alcotest.skip ()
  else
    List.iter
      (fun core ->
        match Affinity.pin core with
        | Ok () -> Alcotest.fail "pin reported success on a platform with no affinity API"
        | Error (`Unsupported _) -> ()
        | Error (`Failed m) -> Alcotest.fail ("expected `Unsupported, got `Failed: " ^ m))
      [ 0; 1; 9999 ]


let supported_platforms_actually_pin () =
  if not Affinity.available then Alcotest.skip ()
  else (
    (match Affinity.pin 0 with
    | Ok () -> ()
    | Error e -> Alcotest.fail ("pinning core 0 failed: " ^ Affinity.error_to_string e)) ;
    (* Out of range must be refused, not silently accepted. CPU_SET past CPU_SETSIZE would corrupt
       the mask, so the stub bounds-checks before touching it. *)
    match Affinity.pin 100_000 with
    | Ok () -> Alcotest.fail "pinning to a nonexistent core reported success"
    | Error (`Failed _) -> ()
    | Error (`Unsupported _) -> Alcotest.fail "available is true but pin says unsupported")


let isolate_cpu_does_not_lie () =
  (* The regression fence for the defect: this returned [Ok ()] unconditionally. *)
  match (Affinity.available, Benchmark.CPUOptimization.isolate_cpu 0) with
  | true, Ok () -> ()
  | true, Error m -> Alcotest.fail ("isolate_cpu failed on a platform that supports pinning: " ^ m)
  | false, Error _ -> ()
  | false, Ok () -> Alcotest.fail "isolate_cpu reported success on a platform with no affinity API"


let governor_is_not_claimed () =
  (* Also previously [Ok ()] after printing "not available in stub mode". *)
  match Benchmark.CPUOptimization.optimize_for_latency () with
  | Ok () -> Alcotest.fail "optimize_for_latency claimed to set root-level machine settings"
  | Error _ -> ()


let suite =
  [
    Alcotest.test_case "cpu_count_is_real" `Quick cpu_count_is_real;
    Alcotest.test_case "pin_never_raises" `Quick pin_never_raises;
    Alcotest.test_case "unsupported_platforms_say_so" `Quick unsupported_platforms_say_so;
    Alcotest.test_case "supported_platforms_actually_pin" `Quick supported_platforms_actually_pin;
    Alcotest.test_case "isolate_cpu_does_not_lie" `Quick isolate_cpu_does_not_lie;
    Alcotest.test_case "governor_is_not_claimed" `Quick governor_is_not_claimed;
  ]
