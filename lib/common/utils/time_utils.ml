(** High-resolution timing utilities for ultra-low latency trading *)

open Base

(** Time representation in nanoseconds since Unix epoch *)
type timestamp_ns = int64

(** Duration in nanoseconds *)
type duration_ns = int64

(** Statistics type for latency analysis *)
type latency_stats = {
  count : int;
  total : duration_ns;
  avg : duration_ns;
  min_duration : duration_ns;
  max_duration : duration_ns;
  median : duration_ns;
  p95 : duration_ns;
  p99 : duration_ns;
}

(** High-resolution clock module *)
module Clock = struct
  (* clock_gettime via C stubs, not Unix.gettimeofday.

     gettimeofday is the wall clock: it steps under NTP correction, a manual clock change or a VM
     resume, so any duration measured by subtracting two readings can come out negative. Telemetry
     discards negative samples, so a clock step used to delete latency data silently. It is also
     microsecond-granular, which is coarse for a function returning nanoseconds. *)

  external monotonic_ns : unit -> int64 = "algostream_clock_monotonic_ns"

  external realtime_ns : unit -> int64 = "algostream_clock_realtime_ns"

  (** Never decreases. The epoch is unspecified, so only differences are meaningful — which is what
      makes it the right clock for latency. *)
  let now_monotonic_ns () = monotonic_ns ()

  (** Wall clock, nanoseconds since the Unix epoch. Steps. Use it for anything a human reads and
      never for measuring a duration. *)
  let now_realtime_ns () = realtime_ns ()
end

(** Timestamp creation and manipulation *)
module Timestamp = struct
  let now () = Clock.now_realtime_ns ()

  let now_monotonic () = Clock.now_monotonic_ns ()

  let of_unix_time_s unix_time = Float.(unix_time * 1_000_000_000.0) |> Float.to_int64

  let to_unix_time_s timestamp_ns = Int64.to_float timestamp_ns /. 1_000_000_000.0

  let of_unix_time_ms unix_time_ms = Int64.(unix_time_ms * 1_000_000L)

  let to_unix_time_ms timestamp_ns = Int64.(timestamp_ns / 1_000_000L)

  let of_unix_time_us unix_time_us = Int64.(unix_time_us * 1_000L)

  let to_unix_time_us timestamp_ns = Int64.(timestamp_ns / 1_000L)

  let add_duration timestamp_ns duration_ns = Int64.(timestamp_ns + duration_ns)

  let sub_duration timestamp_ns duration_ns = Int64.(timestamp_ns - duration_ns)

  let diff t1 t2 = Int64.(t1 - t2)

  let compare = Int64.compare

  let to_string timestamp_ns =
    let unix_time = to_unix_time_s timestamp_ns in
      Printf.sprintf "%.9f" unix_time
end

(** Duration utilities *)
module Duration = struct
  let nanosecond = 1L

  let microsecond = 1_000L

  let millisecond = 1_000_000L

  let second = 1_000_000_000L

  let of_ns ns = ns

  let of_us us = Int64.(us * microsecond)

  let of_ms ms = Int64.(ms * millisecond)

  let of_s s = Int64.(s * second)

  let to_ns duration_ns = duration_ns

  let to_us duration_ns = Int64.(duration_ns / microsecond)

  let to_ms duration_ns = Int64.(duration_ns / millisecond)

  let to_s duration_ns = Int64.(duration_ns / second)

  let to_float_s duration_ns = Int64.to_float duration_ns /. 1_000_000_000.0

  let to_float_ms duration_ns = Int64.to_float duration_ns /. 1_000_000.0

  let to_float_us duration_ns = Int64.to_float duration_ns /. 1_000.0

  let add d1 d2 = Int64.(d1 + d2)

  let sub d1 d2 = Int64.(d1 - d2)

  let mul duration_ns factor = Int64.(duration_ns * Int64.of_int factor)

  let div duration_ns divisor = Int64.(duration_ns / Int64.of_int divisor)

  let compare = Int64.compare

  let to_string duration_ns =
    if Int64.(duration_ns < microsecond) then Printf.sprintf "%Ldns" duration_ns
    else if Int64.(duration_ns < millisecond) then Printf.sprintf "%.3fμs" (to_float_us duration_ns)
    else if Int64.(duration_ns < second) then Printf.sprintf "%.3fms" (to_float_ms duration_ns)
    else Printf.sprintf "%.3fs" (to_float_s duration_ns)
end

(** High-precision timer for performance measurement *)
module Timer = struct
  type t = {
    start_time : timestamp_ns;
    mutable total_duration : duration_ns;
    mutable lap_count : int;
  }

  let create () = { start_time = Clock.now_monotonic_ns (); total_duration = 0L; lap_count = 0 }

  let start () = { start_time = Clock.now_monotonic_ns (); total_duration = 0L; lap_count = 0 }

  let lap timer =
    let current_time = Clock.now_monotonic_ns () in
    let lap_duration = Int64.(current_time - timer.start_time - timer.total_duration) in
      timer.total_duration <- Int64.(timer.total_duration + lap_duration) ;
      timer.lap_count <- timer.lap_count + 1 ;
      lap_duration


  let elapsed timer =
    let current_time = Clock.now_monotonic_ns () in
      Int64.(current_time - timer.start_time)


  let reset timer =
    timer.total_duration <- 0L ;
    timer.lap_count <- 0


  let average_lap_time timer =
    if timer.lap_count = 0 then 0L else Int64.(timer.total_duration / Int64.of_int timer.lap_count)
end

(** Latency measurement utilities *)
module Latency = struct
  type measurement = {
    start_ns : timestamp_ns;
    end_ns : timestamp_ns;
    duration_ns : duration_ns;
    label : string;
  }

  type tracker = {
    measurements : measurement list ref;
    start_time : timestamp_ns option ref;
    current_label : string option ref;
  }

  let create_tracker () = { measurements = ref []; start_time = ref None; current_label = ref None }

  let start_measurement tracker label =
    tracker.start_time := Some (Clock.now_monotonic_ns ()) ;
    tracker.current_label := Some label


  let end_measurement tracker =
    match (!(tracker.start_time), !(tracker.current_label)) with
    | Some start_ns, Some label ->
      let end_ns = Clock.now_monotonic_ns () in
      let duration_ns = Int64.(end_ns - start_ns) in
      let measurement = { start_ns; end_ns; duration_ns; label } in
        tracker.measurements := measurement :: !(tracker.measurements) ;
        tracker.start_time := None ;
        tracker.current_label := None ;
        Some measurement
    | _ -> None


  let get_measurements tracker = List.rev !(tracker.measurements)

  let clear_measurements tracker = tracker.measurements := []

  let measure_function label f =
    let start_ns = Clock.now_monotonic_ns () in
    let result = f () in
    let end_ns = Clock.now_monotonic_ns () in
    let duration_ns = Int64.(end_ns - start_ns) in
    let measurement = { start_ns; end_ns; duration_ns; label } in
      (result, measurement)


  let get_statistics measurements =
    let durations = List.map measurements ~f:(fun m -> m.duration_ns) in
    let count = List.length durations in
      if count = 0 then None
      else
        let total = List.fold durations ~init:0L ~f:Int64.( + ) in
        let avg = Int64.(total / Int64.of_int count) in
        let min_duration =
          List.min_elt durations ~compare:Int64.compare |> Option.value ~default:0L in
        let max_duration =
          List.max_elt durations ~compare:Int64.compare |> Option.value ~default:0L in

        (* Calculate median *)
        let sorted = List.sort durations ~compare:Int64.compare in
        let median =
          if count % 2 = 1 then List.nth_exn sorted (count / 2)
          else
            let mid1 = List.nth_exn sorted ((count / 2) - 1) in
            let mid2 = List.nth_exn sorted (count / 2) in
              Int64.((mid1 + mid2) / 2L) in

        (* Calculate 95th and 99th percentiles *)
        let p95_idx = Int.min (count - 1) (count * 95 / 100) in
        let p99_idx = Int.min (count - 1) (count * 99 / 100) in
        let p95 = List.nth_exn sorted p95_idx in
        let p99 = List.nth_exn sorted p99_idx in

        Some { count; total; avg; min_duration; max_duration; median; p95; p99 }
end

(** Real-time latency monitoring *)
module LatencyMonitor = struct
  type t = {
    window_size : int;
    measurements : duration_ns Queue.t;
    total : duration_ns ref;
    max_latency : duration_ns ref;
    violation_count : int ref;
    violation_threshold_ns : duration_ns;
  }

  let create ~window_size ~violation_threshold_ns =
    {
      window_size;
      measurements = Queue.create ();
      total = ref 0L;
      max_latency = ref 0L;
      violation_count = ref 0;
      violation_threshold_ns;
    }


  let add_measurement monitor duration_ns =
    (* Add new measurement *)
    Queue.enqueue monitor.measurements duration_ns ;
    (monitor.total := Int64.(!(monitor.total) + duration_ns)) ;

    (* Update max latency *)
    if Int64.(duration_ns > !(monitor.max_latency)) then monitor.max_latency := duration_ns ;

    (* Check for SLA violation *)
    if Int64.(duration_ns > monitor.violation_threshold_ns) then Int.incr monitor.violation_count ;

    (* Remove old measurements if window is full *)
    if Queue.length monitor.measurements > monitor.window_size then
      match Queue.dequeue monitor.measurements with
      | Some old_duration -> monitor.total := Int64.(!(monitor.total) - old_duration)
      | None -> ()


  let get_current_avg monitor =
    let count = Queue.length monitor.measurements in
      if count = 0 then 0L else Int64.(!(monitor.total) / Int64.of_int count)


  let get_max_latency monitor = !(monitor.max_latency)

  let get_violation_count monitor = !(monitor.violation_count)

  let reset monitor =
    Queue.clear monitor.measurements ;
    monitor.total := 0L ;
    monitor.max_latency := 0L ;
    monitor.violation_count := 0
end

(** Sleep with high precision *)
module Sleep = struct
  let nanosleep duration_ns =
    let duration_s = Int64.to_float duration_ns /. 1_000_000_000.0 in
      Unix.sleepf duration_s


  let sleep_ns duration_ns = nanosleep duration_ns

  let sleep_us duration_us = nanosleep (Duration.of_us duration_us)

  let sleep_ms duration_ms = nanosleep (Duration.of_ms duration_ms)

  (** Busy wait for very short durations (< 10μs) *)
  let busy_wait_ns target_duration_ns =
    let start_time = Clock.now_monotonic_ns () in
    let rec wait_loop () =
      let current_time = Clock.now_monotonic_ns () in
        if Int64.(current_time - start_time < target_duration_ns) then wait_loop () in
      wait_loop ()


  let busy_wait_us duration_us = busy_wait_ns (Duration.of_us duration_us)
end
