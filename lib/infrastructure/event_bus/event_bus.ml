module Clock = Algostream_common_utils.Time_utils.Clock

(* Internal envelope: the event plus the timestamp at which it was enqueued. Used to compute
   enqueue_to_dispatch latency without modifying Event.t. *)
type envelope = {
  event : Event_types.Event.t;
  enqueued_ns : int64;
}

(* Flow counters. Plain [int Atomic.t] rather than [int64]: OCaml ints are 63-bit, so overflow is
   not reachable, and [Atomic.incr] on an int is a single instruction with no boxing. The public
   record widens to int64 to match every other stats record in the tree. *)
type flow_counters = {
  published : int Atomic.t array;  (** indexed by [Priority.to_int] *)
  dropped : int Atomic.t array;
  dispatched : int Atomic.t;
  handler_errors : int Atomic.t;
}

type flow_stats = {
  published_per_band : int64 array;
  dropped_per_band : int64 array;
  total_published : int64;
  total_dropped : int64;
  dispatched : int64;
  handler_errors : int64;
}

type t = {
  pq : envelope Priority_queue.t;
  subscribers : Subscription.t list Atomic.t;
  ids : Subscription.Id_allocator.t;
  instrumentation : Instrumentation.t;
  flow : flow_counters;
  running : bool Atomic.t;
  stop_requested : bool Atomic.t;
  mutable dispatcher : unit Domain.t option;
  at_exit_installed : bool Atomic.t;
}

let dummy_envelope =
  {
    event =
      {
        sequence_id = 0L;
        timestamp_ns = 0L;
        priority = Event_types.Priority.Low;
        source = "";
        payload = Event_types.Event.Heartbeat;
      };
    enqueued_ns = 0L;
  }


let create ?(capacity_per_band = 4096) ?(sla_ns = 5_000_000L) () =
  {
    pq = Priority_queue.create ~capacity_per_band ~dummy:dummy_envelope;
    subscribers = Atomic.make [];
    ids = Subscription.Id_allocator.create ();
    instrumentation = Instrumentation.create ~sla_ns ();
    flow =
      {
        published = Array.init Event_types.Priority.num_bands (fun _ -> Atomic.make 0);
        dropped = Array.init Event_types.Priority.num_bands (fun _ -> Atomic.make 0);
        dispatched = Atomic.make 0;
        handler_errors = Atomic.make 0;
      };
    running = Atomic.make false;
    stop_requested = Atomic.make false;
    dispatcher = None;
    at_exit_installed = Atomic.make false;
  }


let try_publish t event =
  let t0 = Clock.now_monotonic_ns () in
  let env = { event; enqueued_ns = t0 } in
  let pushed = Priority_queue.try_push t.pq event.priority env in
  let t1 = Clock.now_monotonic_ns () in
  let band = Event_types.Priority.to_int event.priority in
    Atomic.incr (if pushed then t.flow.published.(band) else t.flow.dropped.(band)) ;
    Instrumentation.record t.instrumentation Publish_to_enqueue (Int64.sub t1 t0) ;
    pushed


(* [publish] discards the push result by design — it is the fire-and-forget entry point. The drop is
   still counted in [try_publish], so a caller that ignores the bool no longer makes the loss
   invisible. *)
let publish t event = ignore (try_publish t event : bool)

let snapshot_subscribers t = Atomic.get t.subscribers

let dispatch_one t env =
  let t_dispatch = Clock.now_monotonic_ns () in
    Instrumentation.record t.instrumentation Enqueue_to_dispatch
      (Int64.sub t_dispatch env.enqueued_ns) ;
    let subs = snapshot_subscribers t in
      List.iter
        (fun (sub : Subscription.t) ->
          if Subscription.Filter.matches sub.filter env.event then (
            let h0 = Clock.now_monotonic_ns () in
              (* A raising handler must not stop the dispatcher, but a silently dead subscriber is
                 worse than a noisy one — count it so monitoring can see it. *)
              (try sub.handler env.event with _ -> Atomic.incr t.flow.handler_errors) ;
              let h1 = Clock.now_monotonic_ns () in
                Instrumentation.record t.instrumentation Dispatch_to_handler (Int64.sub h1 h0)))
        subs ;
      Atomic.incr t.flow.dispatched ;
      let t_end = Clock.now_monotonic_ns () in
        Instrumentation.record t.instrumentation End_to_end (Int64.sub t_end env.event.timestamp_ns)


let dispatcher_loop t =
  while not (Atomic.get t.stop_requested) do
    match Priority_queue.try_pop t.pq with
    | Some (env, _) -> dispatch_one t env
    | None ->
      (* PQ is empty: brief sleep to avoid pinning a core. 100us keeps end-to-end latency well under
         the 5ms SLA while leaving the core available for other domains. *)
      Algostream_common_utils.Time_utils.Sleep.sleep_us 100L
  done ;
  (* Drain remaining events on shutdown (best-effort). *)
  let rec drain () =
    match Priority_queue.try_pop t.pq with
    | Some (env, _) ->
      dispatch_one t env ;
      drain ()
    | None -> () in
    drain ()


let install_at_exit_hook_once t =
  if Atomic.compare_and_set t.at_exit_installed false true then
    Stdlib.at_exit (fun () ->
      if Atomic.get t.running then (
        Atomic.set t.stop_requested true ;
        match t.dispatcher with
        | Some d ->
          (try Domain.join d with _ -> ()) ;
          t.dispatcher <- None
        | None ->
          () ;
          Atomic.set t.running false))


let start t =
  if Atomic.compare_and_set t.running false true then (
    Atomic.set t.stop_requested false ;
    t.dispatcher <-
      Some
        (Domain.spawn (fun () ->
           Algostream_common_utils.Affinity.claim ~name:"bus.dispatcher" ;
           dispatcher_loop t)) ;
    install_at_exit_hook_once t)


let stop t =
  if Atomic.compare_and_set t.running true false then (
    Atomic.set t.stop_requested true ;
    match t.dispatcher with
    | Some d ->
      (try Domain.join d with _ -> ()) ;
      t.dispatcher <- None
    | None -> ())


let rec subscribe_internal t sub =
  let cur = Atomic.get t.subscribers in
  let next = sub :: cur in
    if Atomic.compare_and_set t.subscribers cur next then sub.id else subscribe_internal t sub


let subscribe_filtered t filter handler =
  let id = Subscription.Id_allocator.next t.ids in
  let sub = Subscription.create ~id ~filter ~handler in
    subscribe_internal t sub


let subscribe t handler = subscribe_filtered t Subscription.Filter.any handler

let rec unsubscribe t id =
  let cur = Atomic.get t.subscribers in
  let next = List.filter (fun (s : Subscription.t) -> s.id <> id) cur in
    if Atomic.compare_and_set t.subscribers cur next then () else unsubscribe t id


let subscriber_count t = List.length (Atomic.get t.subscribers)

let depth t = Priority_queue.size t.pq

let instrumentation t = t.instrumentation

let stats t = Instrumentation.snapshot t.instrumentation

let depth_per_band t = Priority_queue.depth_per_band t.pq

let flow_stats t =
  let read arr = Array.map (fun a -> Int64.of_int (Atomic.get a)) arr in
  let sum arr = Array.fold_left Int64.add 0L arr in
  let published_per_band = read t.flow.published in
  let dropped_per_band = read t.flow.dropped in
    {
      published_per_band;
      dropped_per_band;
      total_published = sum published_per_band;
      total_dropped = sum dropped_per_band;
      dispatched = Int64.of_int (Atomic.get t.flow.dispatched);
      handler_errors = Int64.of_int (Atomic.get t.flow.handler_errors);
    }
