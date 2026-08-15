module Event_bus = Algostream_infrastructure_event_bus.Event_bus
module Event_types = Algostream_infrastructure_event_bus.Event_types
module Subscription = Algostream_infrastructure_event_bus.Subscription
module SPSCQueue = Algostream_common_utils.Data_structures.SPSCQueue
module Data_source = Algostream_backtest.Data_source
module Clock = Algostream_common_utils.Time_utils.Clock

let src = Logs.Src.create "algostream.runtime.supervisor"

module Log = (val Logs.src_log src : Logs.LOG)

type t = {
  bus : Event_bus.t;
  queue : Data_source.record SPSCQueue.t;
  instances : Instance.t list Atomic.t;
  stop_flag : bool Atomic.t;
  joined : bool Atomic.t;
  domain : unit Domain.t;
  subscription_id : Subscription.subscription_id;
  n_events : int Atomic.t;
  n_dropped : int Atomic.t;
}

let default_queue_capacity = 65_536

(* Built on demand rather than cached.

   An earlier version republished this from the drain loop every N records, which meant the
   aggregate was only as fresh as the last market event: pausing a strategy on a feed that had gone
   quiet returned ok and then kept reporting "running" indefinitely. Readers call this at UI rate,
   so assembling it here costs nothing that matters and cannot go stale. *)
let build ~instances ~n_events ~n_dropped =
  let xs = List.map Instance.snapshot (Atomic.get instances) in
    {
      Snapshot.ts_ns = Clock.now_monotonic_ns ();
      instances = xs;
      total_nav = List.fold_left (fun a (i : Snapshot.instance) -> a +. i.Snapshot.nav) 0.0 xs;
      total_allocation =
        List.fold_left (fun a (i : Snapshot.instance) -> a +. i.Snapshot.allocation) 0.0 xs;
      n_events = Atomic.get n_events;
      n_dropped_full_queue = Atomic.get n_dropped;
    }


let drain_loop ~queue ~instances ~stop_flag ~n_events =
  let step () =
    match SPSCQueue.dequeue queue with
    | None ->
      (* Yield rather than pin a core. 200us is close enough to the dispatcher's own idle sleep that
         the two do not beat against each other. *)
      Algostream_common_utils.Time_utils.Sleep.sleep_us 200L
    | Some record ->
      Atomic.incr n_events ;
      List.iter
        (fun inst ->
          (* One misbehaving strategy must not stop the others, or the runtime. *)
          try Instance.on_record inst record
          with exn ->
            Log.err (fun m ->
              m "instance %s raised on record: %s" (Instance.id inst) (Printexc.to_string exn)))
        (Atomic.get instances) in
    while not (Atomic.get stop_flag) do
      step ()
    done ;
    (* Drain whatever is left so a stop does not silently discard queued market data. *)
    let rec finish () =
      match SPSCQueue.dequeue queue with
      | None -> ()
      | Some record ->
        Atomic.incr n_events ;
        List.iter
          (fun inst -> try Instance.on_record inst record with _ -> ())
          (Atomic.get instances) ;
        finish () in
      finish ()


let create ~bus ?(queue_capacity = default_queue_capacity) () =
  let queue = SPSCQueue.create ~capacity:queue_capacity in
  let instances = Atomic.make [] in
  let stop_flag = Atomic.make false in
  let n_events = Atomic.make 0 in
  let n_dropped = Atomic.make 0 in
  (* O(1), allocation-light: translate and enqueue. Nothing else may happen on the dispatcher. *)
  let handler (ev : Event_types.Event.t) =
    match Translate.of_payload ev.payload with
    | None -> ()
    | Some record -> if not (SPSCQueue.enqueue queue record) then Atomic.incr n_dropped in
  let filter =
    Subscription.Filter.custom (fun (ev : Event_types.Event.t) ->
      Translate.is_market_payload ev.payload) in
  let subscription_id = Event_bus.subscribe_filtered bus filter handler in
  let domain =
    Domain.spawn (fun () ->
      Algostream_common_utils.Affinity.claim ~name:"runtime.drain" ;
      drain_loop ~queue ~instances ~stop_flag ~n_events) in
    {
      bus;
      queue;
      instances;
      stop_flag;
      joined = Atomic.make false;
      domain;
      subscription_id;
      n_events;
      n_dropped;
    }


(* The duplicate check is inside the CAS retry loop, not before it: two Domains adding the same id
   concurrently must not both observe "absent" and both succeed. Re-reading the list on every
   attempt makes the check and the insert atomic together. *)
let rec add t inst =
  let cur = Atomic.get t.instances in
  let id = Instance.id inst in
    if List.exists (fun i -> String.equal (Instance.id i) id) cur then false
    else if Atomic.compare_and_set t.instances cur (cur @ [ inst ]) then true
    else add t inst


let instances t = Atomic.get t.instances

let nav_curves t = List.map (fun i -> (Instance.id i, Instance.nav_curve i)) (instances t)

let find t ~strategy_id =
  List.find_opt (fun i -> String.equal (Instance.id i) strategy_id) (instances t)


let with_instance t ~strategy_id f =
  match find t ~strategy_id with
  | None -> false
  | Some i ->
    f i ;
    true


let pause t ~strategy_id = with_instance t ~strategy_id Instance.pause

let resume t ~strategy_id = with_instance t ~strategy_id Instance.resume

let stop_instance t ~strategy_id = with_instance t ~strategy_id Instance.stop

let set_allocation t ~strategy_id v =
  with_instance t ~strategy_id (fun i -> Instance.set_allocation i v)


let allocate_evenly t ~total =
  let xs = instances t in
    match List.length xs with
    | 0 -> []
    | n ->
      let each = total /. float_of_int n in
        List.map
          (fun i ->
            Instance.set_allocation i each ;
            (Instance.id i, each))
          xs


let snapshot t = build ~instances:t.instances ~n_events:t.n_events ~n_dropped:t.n_dropped

let dropped_full_queue t = Atomic.get t.n_dropped

let is_running t = not (Atomic.get t.joined)

let stop t =
  if Atomic.compare_and_set t.joined false true then (
    (* Unsubscribe first so nothing new arrives while the loop is finishing, mirroring the ordering
       the other processors use. *)
    Event_bus.unsubscribe t.bus t.subscription_id ;
    List.iter (fun i -> try Instance.stop i with _ -> ()) (instances t) ;
    Atomic.set t.stop_flag true ;
    try Domain.join t.domain with _ -> ())


let telemetry_metrics t () =
  let s = snapshot t in
    [
      ("total_nav", s.Snapshot.total_nav);
      ("total_allocation", s.Snapshot.total_allocation);
      ("instances", float_of_int (List.length s.Snapshot.instances));
      ("events", float_of_int s.Snapshot.n_events);
      ("dropped_full_queue", float_of_int s.Snapshot.n_dropped_full_queue);
      ( "running_instances",
        float_of_int
          (List.length
             (List.filter
                (fun (i : Snapshot.instance) -> i.Snapshot.lifecycle = Snapshot.Running)
                s.Snapshot.instances)) );
    ]
