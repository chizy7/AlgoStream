module Clock = Algostream_common_utils.Time_utils.Clock

type sample = {
  timestamp_ns : int64;
  minor_words : float;
  promoted_words : float;
  major_words : float;
  heap_words : int;
  live_words : int;
  free_words : int;
  stack_size : int;
}

type t = {
  latest : sample option Atomic.t;
  running : bool Atomic.t;
  mutable thread : Thread.t option;
}
[@@warning "-69"]

let create () = { latest = Atomic.make None; running = Atomic.make false; thread = None }

let take_sample () =
  let s = Gc.quick_stat () in
    {
      timestamp_ns = Clock.now_monotonic_ns ();
      minor_words = s.minor_words;
      promoted_words = s.promoted_words;
      major_words = s.major_words;
      heap_words = s.heap_words;
      live_words = s.live_words;
      free_words = s.free_words;
      stack_size = s.stack_size;
    }


let sampler_loop t interval_ms =
  while Atomic.get t.running do
    let s = take_sample () in
      Atomic.set t.latest (Some s) ;
      Thread.delay (Float.of_int interval_ms /. 1000.0)
  done


let start ?(interval_ms = 1000) t =
  if Atomic.compare_and_set t.running false true then
    t.thread <- Some (Thread.create (fun () -> sampler_loop t interval_ms) ())


let stop t =
  if Atomic.compare_and_set t.running true false then
    match t.thread with
    | Some th ->
      (try Thread.join th with _ -> ()) ;
      t.thread <- None
    | None -> ()


let latest t = Atomic.get t.latest

let pp_sample s =
  Printf.sprintf "minor=%.0fw promoted=%.0fw major=%.0fw heap=%dw live=%dw free=%dw stack=%d"
    s.minor_words s.promoted_words s.major_words s.heap_words s.live_words s.free_words s.stack_size


let memtrace_initialized = Atomic.make false

let init_memtrace () =
  if Atomic.compare_and_set memtrace_initialized false true then
    match Sys.getenv_opt "MEMTRACE" with
    | Some path ->
      let _tracer = Memtrace.start_tracing ~context:None ~sampling_rate:1e-4 ~filename:path in
        Printf.eprintf "memory_monitor: memtrace tracing → %s (sampling 1e-4)\n%!" path
    | None -> ()
