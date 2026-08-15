(** The monotonic clock, and the property that was missing.

    [Clock.now_monotonic_ns] was [Unix.gettimeofday] — the wall clock, which steps. Every duration
    measured by subtracting two readings could therefore come out negative under an NTP correction,
    and telemetry discards negative samples, so a clock step deleted latency data with nothing in
    the logs to say so.

    A test cannot make the wall clock step, so none of these prove monotonicity under adversarial
    conditions. What they do is fail loudly if the implementation ever reverts to a wall-clock
    source, which is the regression worth guarding. *)

module Clock = Algostream_common_utils.Time_utils.Clock

let never_decreases () =
  (* The direct regression fence. gettimeofday would pass this on a quiet machine too — that is why
     the resolution and epoch checks below exist as well. *)
  let n = 200_000 in
  let prev = ref (Clock.now_monotonic_ns ()) in
    for _ = 1 to n do
      let now = Clock.now_monotonic_ns () in
        if Int64.compare now !prev < 0 then
          Alcotest.failf "monotonic clock went backwards: %Ld then %Ld" !prev now ;
        prev := now
    done


let differences_are_never_negative () =
  (* What the telemetry path actually does. Histogram.record refuses negatives, so a clock that can
     produce them silently deletes samples. *)
  for _ = 1 to 5_000 do
    let a = Clock.now_monotonic_ns () in
    let b = Clock.now_monotonic_ns () in
      if Int64.compare (Int64.sub b a) 0L < 0 then
        Alcotest.failf "elapsed came out negative: %Ld -> %Ld" a b
  done


let resolution_is_finer_than_a_microsecond () =
  (* gettimeofday is microsecond-granular, so consecutive readings differ by 0 or a multiple of 1000
     ns. clock_gettime resolves finer. Observing any difference that is neither zero nor a multiple
     of 1000 is therefore proof the source is not gettimeofday.

     Sampling rather than asserting on one pair: back-to-back calls can legitimately land in the
     same nanosecond. *)
  let seen = ref false in
    (try
       for _ = 1 to 100_000 do
         let a = Clock.now_monotonic_ns () in
         let b = Clock.now_monotonic_ns () in
         let d = Int64.to_int (Int64.sub b a) in
           if d > 0 && d mod 1000 <> 0 then (
             seen := true ;
             raise Exit)
       done
     with Exit -> ()) ;
    Alcotest.(check bool)
      "sub-microsecond resolution — a wall clock would only ever step in whole microseconds" true
      !seen


let monotonic_is_not_the_wall_clock () =
  (* CLOCK_MONOTONIC counts from an unspecified epoch, typically boot; CLOCK_REALTIME counts from
     1970. On any machine with meaningful uptime the two are far apart. If monotonic were still
     gettimeofday they would be within milliseconds of each other. *)
  let mono = Clock.now_monotonic_ns () in
  let real = Clock.now_realtime_ns () in
  let gap_s = Int64.to_float (Int64.abs (Int64.sub real mono)) /. 1e9 in
    Alcotest.(check bool)
      (Printf.sprintf "monotonic and realtime are different clocks (%.0f s apart)" gap_s)
      true (gap_s > 86_400.0)


let realtime_tracks_the_epoch () =
  (* The counterpart: realtime must still be wall time, since audit records and anything a human
     reads depend on it. *)
  let now = Int64.to_float (Clock.now_realtime_ns ()) /. 1e9 in
  let unix_now = Unix.gettimeofday () in
    Alcotest.(check bool)
      (Printf.sprintf "realtime agrees with Unix.gettimeofday (%.3f s apart)"
         (abs_float (now -. unix_now)))
      true
      (abs_float (now -. unix_now) < 1.0)


let suite =
  [
    Alcotest.test_case "never_decreases" `Quick never_decreases;
    Alcotest.test_case "differences_are_never_negative" `Quick differences_are_never_negative;
    Alcotest.test_case "resolution_is_finer_than_a_microsecond" `Quick
      resolution_is_finer_than_a_microsecond;
    Alcotest.test_case "monotonic_is_not_the_wall_clock" `Quick monotonic_is_not_the_wall_clock;
    Alcotest.test_case "realtime_tracks_the_epoch" `Quick realtime_tracks_the_epoch;
  ]
