(** Benchmarking and optimization utilities for ultra-low latency trading *)

open Base
open Stdio

(** Benchmark result type *)
type benchmark_result = {
  name : string;
  iterations : int;
  total_time_ns : int64;
  avg_time_ns : int64;
  min_time_ns : int64;
  max_time_ns : int64;
  median_time_ns : int64;
  p95_time_ns : int64;
  p99_time_ns : int64;
  std_dev_ns : float;
  throughput_ops_per_sec : float;
}
[@@deriving sexp]

(** Benchmark configuration *)
type benchmark_config = {
  warmup_iterations : int;
  measurement_iterations : int;
  target_latency_ns : int64;
  cpu_affinity : int option;
  gc_settings : [ `Default | `Low_latency | `High_throughput ];
  memory_prefault : bool;
}
[@@deriving sexp]

let default_config =
  {
    warmup_iterations = 1000;
    measurement_iterations = 10000;
    target_latency_ns = 5_000_000L;
    (* 5ms *)
    cpu_affinity = None;
    gc_settings = `Low_latency;
    memory_prefault = true;
  }


(** CPU affinity and performance optimization *)
module CPUOptimization = struct
  let get_cpu_count () = Affinity.cpu_count

  let isolate_cpu cpu_id =
    match Affinity.pin cpu_id with Ok () -> Ok () | Error e -> Error (Affinity.error_to_string e)


  let optimize_for_latency () =
    (* The CPU governor and turbo boost live in sysfs and need root; a process cannot set them for
       itself. This used to print "not available in stub mode" and return [Ok ()], which reported a
       success that had not happened. Say so instead — the operator does this at the machine level,
       and docs/guides/performance_tuning.md carries the commands. *)
    Error
      "cpu governor and turbo boost are root-level machine settings, not process settings; see the \
       performance tuning guide"


  let get_recommended_cpu () =
    let total_cpus = Affinity.cpu_count in
      if total_cpus > 4 then Some (total_cpus - 1) (* Use the last CPU core *) else None
end

(** Memory optimization utilities *)
module MemoryOptimization = struct
  (* Stub implementations *)
  let prefault_memory _ptr _size = ()

  let lock_memory _ptr _size = ()

  let unlock_memory _ptr _size = ()

  let huge_page_alloc _size = Nativeint.zero

  let huge_page_free _ptr _size = ()

  (* Both functions below set only the two fields OCaml 5 actually honours.

     This was measured on the 5.0.0 switch rather than taken from the field names: requesting
     [major_heap_increment] and [max_overhead] leaves both reading back 0, because the OCaml 5 major
     collector is incremental and mark-and-sweep with no compaction, so neither knob exists any
     more. [allocation_policy] is likewise inert. Setting them did nothing but suggest a tuning that
     was not happening.

     [stack_limit] was also being set, to 1 MiB — a 128x *reduction* from the 5.0 default of 128
     MiB, unrelated to GC latency and a live stack-overflow risk for anything deeply recursive.
     Dropped.

     Note [minor_heap_size] is in WORDS, not bytes. The old comment claimed a "2MB minor heap" for
     [2 * 1024 * 1024], which is 2M words — 16 MiB on 64-bit. The effective value is kept, since a
     large minor heap is the right lever here and 16 MiB is a sensible one; only the arithmetic is
     now stated honestly. It matters more than it looks: OCaml 5 minor collections are
     stop-the-world across every Domain, so each one pauses the bus dispatcher, all three processors
     and the runtime at once. Fewer, larger minor collections is the whole game. *)

  let words_per_mib = 1024 * 1024 / (Stdlib.Sys.word_size / 8)

  let optimize_gc_for_latency () =
    Stdlib.Gc.set
      {
        (Stdlib.Gc.get ()) with
        minor_heap_size = 16 * words_per_mib;
        (* fewer stop-the-world minor collections *)
        space_overhead = 80;
        (* spend memory to keep major-GC work down *)
        verbose = 0;
      }


  let optimize_gc_for_throughput () =
    Stdlib.Gc.set
      {
        (Stdlib.Gc.get ()) with
        minor_heap_size = 64 * words_per_mib;
        space_overhead = 120;
        (* tolerate more floating garbage in exchange for less collector work *)
        verbose = 0;
      }


  let prefault_heap () =
    let stats = Stdlib.Gc.stat () in
    let heap_size = stats.heap_words * (Stdlib.Sys.word_size / 8) in
      (* Note: This is a simplified approach - in practice we'd need to iterate through actual
         allocated blocks *)
      printf "Heap size: %d bytes\n" heap_size
end

(** High-precision benchmark runner *)
module BenchmarkRunner = struct
  let setup_environment config =
    (* Set CPU affinity if specified *)
    (match config.cpu_affinity with
    | Some cpu_id ->
      (match CPUOptimization.isolate_cpu cpu_id with
      | Ok () -> ()
      | Error msg -> eprintf "Warning: Failed to set CPU affinity: %s\n" msg)
    | None -> ()) ;

    (* Configure GC based on settings *)
    (match config.gc_settings with
    | `Low_latency -> MemoryOptimization.optimize_gc_for_latency ()
    | `High_throughput -> MemoryOptimization.optimize_gc_for_throughput ()
    | `Default -> ()) ;

    (* Prefault memory if requested *)
    if config.memory_prefault then MemoryOptimization.prefault_heap ()


  let warmup_function f iterations =
    for _i = 1 to iterations do
      let _ = f () in
        ()
    done


  let measure_function f iterations =
    let measurements = Array.create ~len:iterations 0L in

    (* Force GC before measurements to ensure clean state *)
    Stdlib.Gc.full_major () ;

    for i = 0 to iterations - 1 do
      let start_time = Time_utils.Clock.now_monotonic_ns () in
      let _ = f () in
      let end_time = Time_utils.Clock.now_monotonic_ns () in
        measurements.(i) <- Int64.(end_time - start_time)
    done ;

    measurements


  let calculate_statistics name measurements =
    let len = Array.length measurements in
      if len = 0 then failwith "No measurements provided" ;

      (* Sort for percentile calculations *)
      Array.sort measurements ~compare:Int64.compare ;

      let total_time = Array.fold measurements ~init:0L ~f:Int64.( + ) in
      let avg_time = Int64.(total_time / Int64.of_int len) in
      let min_time = measurements.(0) in
      let max_time = measurements.(len - 1) in

      let median_idx = len / 2 in
      let median_time =
        if len % 2 = 1 then measurements.(median_idx)
        else
          let val1 = measurements.(median_idx - 1) in
          let val2 = measurements.(median_idx) in
            Int64.((val1 + val2) / 2L) in

      let p95_idx = Int.min (len - 1) (len * 95 / 100) in
      let p99_idx = Int.min (len - 1) (len * 99 / 100) in
      let p95_time = measurements.(p95_idx) in
      let p99_time = measurements.(p99_idx) in

      (* Calculate standard deviation *)
      let variance_sum =
        Array.fold measurements ~init:0.0 ~f:(fun acc measurement ->
          let diff = Int64.to_float Int64.(measurement - avg_time) in
            acc +. (diff *. diff)) in
      let std_dev = Float.sqrt (variance_sum /. Float.of_int len) in

      (* Calculate throughput (operations per second) *)
      let avg_time_seconds = Int64.to_float avg_time /. 1_000_000_000.0 in
      let throughput = 1.0 /. avg_time_seconds in

      {
        name;
        iterations = len;
        total_time_ns = total_time;
        avg_time_ns = avg_time;
        min_time_ns = min_time;
        max_time_ns = max_time;
        median_time_ns = median_time;
        p95_time_ns = p95_time;
        p99_time_ns = p99_time;
        std_dev_ns = std_dev;
        throughput_ops_per_sec = throughput;
      }


  let run_benchmark ~name ~config ~f =
    setup_environment config ;

    printf "Running benchmark: %s\n" name ;
    printf "Warmup iterations: %d\n" config.warmup_iterations ;
    printf "Measurement iterations: %d\n" config.measurement_iterations ;

    (* Warmup phase *)
    printf "Warming up...\n" ;
    warmup_function f config.warmup_iterations ;

    (* Measurement phase *)
    printf "Measuring...\n" ;
    let measurements = measure_function f config.measurement_iterations in

    (* Calculate and return statistics *)
    calculate_statistics name measurements
end

(** Critical path benchmarks for trading system *)
module TradingBenchmarks = struct
  (* Benchmark data structures *)
  let benchmark_ring_buffer () =
    let buffer = Data_structures.RingBuffer.create ~capacity:1024 42 in
      fun () ->
        Data_structures.RingBuffer.push buffer 123 ;
        let _ = Data_structures.RingBuffer.pop buffer in
          ()


  let benchmark_lock_free_stack () =
    let stack = Data_structures.LockFreeStack.create () in
      fun () ->
        Data_structures.LockFreeStack.push stack 123 ;
        let _ = Data_structures.LockFreeStack.pop stack in
          ()


  let benchmark_order_book_update () =
    let order_book = Data_structures.OrderBook.create ~table_size:1024 in
    let price = ref 100.0 in
      fun () ->
        price := !price +. 0.01 ;
        Data_structures.OrderBook.add_order order_book Bid !price 100.0


  (* Benchmark timing utilities *)
  let benchmark_timestamp_generation () =
   fun () ->
    let _ = Time_utils.Clock.now_monotonic_ns () in
      ()


  let benchmark_timer_operations () =
    let timer = Time_utils.Timer.create () in
      fun () ->
        let _ = Time_utils.Timer.lap timer in
          ()


  (* Benchmark memory-mapped operations *)
  let benchmark_mmap_read () =
    (* Create a temporary file for testing *)
    let temp_file = "/tmp/algostream_benchmark.dat" in
    let fd = Unix.openfile temp_file [ Unix.O_CREAT; Unix.O_RDWR ] 0o644 in
    let _ = Unix.write_substring fd "Hello, World!" 0 13 in
      Unix.close fd ;

      let handle = Memory_mapped.create_mmap temp_file in
        fun () ->
          let _ = Memory_mapped.Reader.read_uint8 handle 0 in
            ()


  (* Benchmark zero-copy message passing *)
  let benchmark_zero_copy_send () =
    let channel = Zero_copy.create_channel ~channel_id:1 ~capacity:64 ~message_size:256 in
    let payload = Bytes.create 128 in
      fun () -> Zero_copy.send_message channel Zero_copy.MessageType.market_data payload


  let benchmark_zero_copy_receive () =
    let channel = Zero_copy.create_channel ~channel_id:2 ~capacity:64 ~message_size:256 in
      fun () ->
        let _ = Zero_copy.try_receive_message channel in
          ()


  (* Run all trading system benchmarks *)
  let run_all_benchmarks ?(config = default_config) () =
    let benchmarks =
      [
        ("RingBuffer Push/Pop", benchmark_ring_buffer ());
        ("LockFreeStack Push/Pop", benchmark_lock_free_stack ());
        ("OrderBook Update", benchmark_order_book_update ());
        ("Timestamp Generation", benchmark_timestamp_generation ());
        ("Timer Operations", benchmark_timer_operations ());
        ("Memory-Mapped Read", benchmark_mmap_read ());
        ("Zero-Copy Send", benchmark_zero_copy_send ());
        ("Zero-Copy Receive", benchmark_zero_copy_receive ());
      ] in

    let results =
      List.map benchmarks ~f:(fun (name, benchmark_func) ->
        BenchmarkRunner.run_benchmark ~name ~config ~f:benchmark_func) in

    results
end

(** Performance analysis and reporting *)
module PerformanceAnalysis = struct
  let format_time_ns time_ns =
    if Int64.(time_ns < 1000L) then Printf.sprintf "%Ld ns" time_ns
    else if Int64.(time_ns < 1_000_000L) then
      Printf.sprintf "%.2f μs" (Int64.to_float time_ns /. 1000.0)
    else if Int64.(time_ns < 1_000_000_000L) then
      Printf.sprintf "%.2f ms" (Int64.to_float time_ns /. 1_000_000.0)
    else Printf.sprintf "%.2f s" (Int64.to_float time_ns /. 1_000_000_000.0)


  let format_throughput ops_per_sec =
    if Float.(ops_per_sec > 1_000_000.0) then
      Printf.sprintf "%.2f M ops/sec" (ops_per_sec /. 1_000_000.0)
    else if Float.(ops_per_sec > 1_000.0) then
      Printf.sprintf "%.2f K ops/sec" (ops_per_sec /. 1_000.0)
    else Printf.sprintf "%.2f ops/sec" ops_per_sec


  let print_benchmark_result result =
    printf "\n=== Benchmark: %s ===\n" result.name ;
    printf "Iterations: %d\n" result.iterations ;
    printf "Average: %s\n" (format_time_ns result.avg_time_ns) ;
    printf "Median:  %s\n" (format_time_ns result.median_time_ns) ;
    printf "Min:     %s\n" (format_time_ns result.min_time_ns) ;
    printf "Max:     %s\n" (format_time_ns result.max_time_ns) ;
    printf "95th %%:  %s\n" (format_time_ns result.p95_time_ns) ;
    printf "99th %%:  %s\n" (format_time_ns result.p99_time_ns) ;
    printf "Std Dev: %s\n" (format_time_ns (Int64.of_float result.std_dev_ns)) ;
    printf "Throughput: %s\n" (format_throughput result.throughput_ops_per_sec) ;

    (* Check if performance meets targets *)
    if Int64.(result.avg_time_ns <= 5_000_000L) then printf "✅ PASS: Average latency ≤ 5ms target\n"
    else printf "❌ FAIL: Average latency exceeds 5ms target\n" ;

    if Int64.(result.p99_time_ns <= 10_000_000L) then
      printf "✅ PASS: 99th percentile ≤ 10ms target\n"
    else printf "❌ FAIL: 99th percentile exceeds 10ms target\n"


  let generate_performance_report results =
    print_endline "" ;
    printf "╔══════════════════════════════════════════════════════════════╗\n" ;
    printf "║                    ALGOSTREAM PERFORMANCE REPORT             ║\n" ;
    printf "╚══════════════════════════════════════════════════════════════╝\n" ;

    List.iter results ~f:print_benchmark_result ;

    printf "\n" ;
    printf "╔══════════════════════════════════════════════════════════════╗\n" ;
    printf "║                         SUMMARY                              ║\n" ;
    printf "╚══════════════════════════════════════════════════════════════╝\n" ;

    let passing_benchmarks =
      List.count results ~f:(fun result -> Int64.(result.avg_time_ns <= 5_000_000L)) in

    let total_benchmarks = List.length results in

    printf "Benchmarks passing latency target: %d/%d\n" passing_benchmarks total_benchmarks ;

    if passing_benchmarks = total_benchmarks then
      printf "🎉 ALL BENCHMARKS PASSED - System meets sub-5ms latency requirements!\n"
    else printf "⚠️  Some benchmarks failed - Optimization needed for production deployment\n" ;

    (* Identify bottlenecks *)
    let slowest_benchmark =
      List.max_elt results ~compare:(fun a b -> Int64.compare a.avg_time_ns b.avg_time_ns) in

    match slowest_benchmark with
    | Some result ->
      printf "\nSlowest component: %s (%s average)\n" result.name
        (format_time_ns result.avg_time_ns)
    | None -> ()


  let export_to_csv results filename =
    let oc = Out_channel.create filename in
      Out_channel.fprintf oc
        "Benchmark,Iterations,Avg_ns,Median_ns,Min_ns,Max_ns,P95_ns,P99_ns,StdDev_ns,Throughput_ops_sec\n" ;

      List.iter results ~f:(fun result ->
        Out_channel.fprintf oc "%s,%d,%Ld,%Ld,%Ld,%Ld,%Ld,%Ld,%.2f,%.2f\n" result.name
          result.iterations result.avg_time_ns result.median_time_ns result.min_time_ns
          result.max_time_ns result.p95_time_ns result.p99_time_ns result.std_dev_ns
          result.throughput_ops_per_sec) ;

      Out_channel.close oc ;
      printf "Performance results exported to %s\n" filename


  let json_escape s =
    let buf = Buffer.create (String.length s + 2) in
      String.iter s ~f:(fun c ->
        match c with
        | '"' -> Buffer.add_string buf "\\\""
        | '\\' -> Buffer.add_string buf "\\\\"
        | '\n' -> Buffer.add_string buf "\\n"
        | '\r' -> Buffer.add_string buf "\\r"
        | '\t' -> Buffer.add_string buf "\\t"
        | c when Char.to_int c < 0x20 ->
          Buffer.add_string buf (Printf.sprintf "\\u%04x" (Char.to_int c))
        | c -> Buffer.add_char buf c) ;
      Buffer.contents buf


  let export_to_json results filename =
    let oc = Out_channel.create filename in
      Out_channel.output_string oc "[\n" ;
      List.iteri results ~f:(fun i result ->
        let extra =
          Printf.sprintf "p95=%Ldns p99=%Ldns iter=%d" result.p95_time_ns result.p99_time_ns
            result.iterations in
          Out_channel.fprintf oc
            "  {\"name\":\"%s\",\"unit\":\"ns\",\"value\":%Ld,\"extra\":\"%s\"}%s\n"
            (json_escape result.name) result.avg_time_ns (json_escape extra)
            (if i = List.length results - 1 then "" else ",")) ;
      Out_channel.output_string oc "]\n" ;
      Out_channel.close oc ;
      printf "Performance results exported to %s\n" filename
end

(** Continuous performance monitoring *)
module PerformanceMonitor = struct
  type monitor = {
    benchmarks : (string * (unit -> unit)) list;
    config : benchmark_config;
    last_results : benchmark_result list ref;
    mutable running : bool;
  }

  let create ~benchmarks ~config = { benchmarks; config; last_results = ref []; running = false }

  let run_monitoring_cycle monitor =
    let results =
      List.map monitor.benchmarks ~f:(fun (name, benchmark_func) ->
        BenchmarkRunner.run_benchmark ~name ~config:monitor.config ~f:benchmark_func) in

    monitor.last_results := results ;

    (* Check for performance regressions *)
    List.iter results ~f:(fun result ->
      if Int64.(result.avg_time_ns > 10_000_000L) then
        eprintf "PERFORMANCE ALERT: %s average latency %s exceeds 10ms threshold!\n" result.name
          (PerformanceAnalysis.format_time_ns result.avg_time_ns)) ;

    results


  let start_continuous_monitoring monitor ~interval_seconds =
    monitor.running <- true ;
    printf "Starting continuous performance monitoring (interval: %d seconds)\n" interval_seconds ;

    let rec monitoring_loop () =
      if monitor.running then (
        let _ = run_monitoring_cycle monitor in
          Unix.sleep interval_seconds ;
          monitoring_loop ()) in
      monitoring_loop ()


  let stop_monitoring monitor =
    monitor.running <- false ;
    printf "Performance monitoring stopped\n"


  let get_last_results monitor = !(monitor.last_results)
end
