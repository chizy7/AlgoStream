module LM = Algostream_common_utils.Time_utils.LatencyMonitor

type phase =
  | Publish_to_enqueue
  | Enqueue_to_dispatch
  | Dispatch_to_handler
  | End_to_end

let phase_to_string = function
  | Publish_to_enqueue -> "publish_to_enqueue"
  | Enqueue_to_dispatch -> "enqueue_to_dispatch"
  | Dispatch_to_handler -> "dispatch_to_handler"
  | End_to_end -> "end_to_end"


type t = {
  enabled : bool Atomic.t;
  publish_to_enqueue : LM.t;
  enqueue_to_dispatch : LM.t;
  dispatch_to_handler : LM.t;
  end_to_end : LM.t;
  counts : int Atomic.t array;
}

let create ?(window_size = 4096) ?(sla_ns = 5_000_000L) () =
  {
    enabled = Atomic.make true;
    publish_to_enqueue = LM.create ~window_size ~violation_threshold_ns:sla_ns;
    enqueue_to_dispatch = LM.create ~window_size ~violation_threshold_ns:sla_ns;
    dispatch_to_handler = LM.create ~window_size ~violation_threshold_ns:sla_ns;
    end_to_end = LM.create ~window_size ~violation_threshold_ns:sla_ns;
    counts = Array.init 4 (fun _ -> Atomic.make 0);
  }


let monitor_for t = function
  | Publish_to_enqueue -> t.publish_to_enqueue
  | Enqueue_to_dispatch -> t.enqueue_to_dispatch
  | Dispatch_to_handler -> t.dispatch_to_handler
  | End_to_end -> t.end_to_end


let phase_index = function
  | Publish_to_enqueue -> 0
  | Enqueue_to_dispatch -> 1
  | Dispatch_to_handler -> 2
  | End_to_end -> 3


let record t phase duration_ns =
  if Atomic.get t.enabled then (
    LM.add_measurement (monitor_for t phase) duration_ns ;
    let i = phase_index phase in
    let _ = Atomic.fetch_and_add t.counts.(i) 1 in
      ())


let set_enabled t v = Atomic.set t.enabled v

let is_enabled t = Atomic.get t.enabled

type phase_stats = {
  count : int;
  avg_ns : int64;
  max_ns : int64;
  violations : int;
}

type stats = {
  publish_to_enqueue : phase_stats;
  enqueue_to_dispatch : phase_stats;
  dispatch_to_handler : phase_stats;
  end_to_end : phase_stats;
}

let snapshot_phase t phase =
  let m = monitor_for t phase in
    {
      count = Atomic.get t.counts.(phase_index phase);
      avg_ns = LM.get_current_avg m;
      max_ns = LM.get_max_latency m;
      violations = LM.get_violation_count m;
    }


let snapshot t =
  {
    publish_to_enqueue = snapshot_phase t Publish_to_enqueue;
    enqueue_to_dispatch = snapshot_phase t Enqueue_to_dispatch;
    dispatch_to_handler = snapshot_phase t Dispatch_to_handler;
    end_to_end = snapshot_phase t End_to_end;
  }


let format_phase name s =
  Printf.sprintf "  %-22s count=%d avg=%Ldns max=%Ldns violations=%d" name s.count s.avg_ns s.max_ns
    s.violations


let pp_stats s =
  String.concat "\n"
    [
      "event-bus instrumentation:";
      format_phase "publish_to_enqueue" s.publish_to_enqueue;
      format_phase "enqueue_to_dispatch" s.enqueue_to_dispatch;
      format_phase "dispatch_to_handler" s.dispatch_to_handler;
      format_phase "end_to_end" s.end_to_end;
    ]
