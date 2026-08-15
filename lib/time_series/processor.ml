module Event_bus = Algostream_infrastructure_event_bus.Event_bus
module Subscription = Algostream_infrastructure_event_bus.Subscription
module Event_types = Algostream_infrastructure_event_bus.Event_types
module SPSCQueue = Algostream_common_utils.Data_structures.SPSCQueue
module Filters = Algostream_analytics.Filters

let log_src = Logs.Src.create "algostream.time_series.processor"

module Log = (val Logs.src_log log_src : Logs.LOG)

(* ───── tick handoff ───────────────────────────────────────────────── *)

type tick_event = {
  symbol : string;
  ts_ns : int64;
  price : float;
  size : float;
}

(* ───── per-(symbol, interval) state ──────────────────────────────── *)

module Key = struct
  type t = string * int64

  let equal (s1, i1) (s2, i2) = String.equal s1 s2 && Int64.equal i1 i2

  let hash (s, i) = Hashtbl.hash (s, i)
end

module KH = Hashtbl.Make (Key)

type cell = {
  builder : Bar_builder.t;
  ring : Bar.t array Atomic.t; (* immutable array, replaced on each bar close *)
  mutable last_event_ts_ns : int64;
}

type stats = {
  ticks_observed : int64;
  ticks_processed : int64;
  ticks_rejected_sanity : int64;
  ticks_dropped_full_queue : int64;
  bars_emitted : int64;
  late_ticks : int64;
  active_keys : int;
}

type t = {
  bus : Event_bus.t;
  intervals_ns : int64 list;
  ring_size : int;
  max_active_keys : int;
  queue : tick_event SPSCQueue.t;
  stop_flag : bool Atomic.t;
  joined : bool Atomic.t;
  domain : unit Domain.t;
  subscription_id : Subscription.subscription_id;
  ticks_observed : int64 Atomic.t;
  ticks_processed : int64 Atomic.t;
  ticks_rejected_sanity : int64 Atomic.t;
  ticks_dropped_full_queue : int64 Atomic.t;
  bars_emitted : int64 Atomic.t;
  late_ticks : int64 Atomic.t;
  active_keys : int Atomic.t;
  index : (string * int64 * Bar.t array Atomic.t) list Atomic.t;
}

let incr_atomic_int64 a =
  let rec loop () =
    let cur = Atomic.get a in
    let next = Int64.add cur 1L in
      if Atomic.compare_and_set a cur next then () else loop () in
    loop ()


let make_filter () =
  let mt = Algostream_common_utils.Zero_copy.MessageType.market_data in
  let tt = Algostream_common_utils.Zero_copy.MessageType.trade_execution in
    Subscription.Filter.or_
      (Subscription.Filter.by_message_type mt)
      (Subscription.Filter.by_message_type tt)


let payload_to_tick (payload : Event_types.Event.payload) : tick_event option =
  match payload with
  | Market_tick { symbol; timestamp_ns; price; volume; _ } ->
    Some { symbol; ts_ns = timestamp_ns; price; size = volume }
  | Trade_print { symbol; timestamp_ns; price; size; _ } ->
    Some { symbol; ts_ns = timestamp_ns; price; size }
  | _ -> None


(* Push a fresh ring snapshot when a bar closes. The new array is the last [ring_size] bars (newest
   last). The previous Atomic value is discarded (immutable). *)
let push_bar ~ring_size cell new_bar =
  let prev = Atomic.get cell.ring in
  let prev_n = Array.length prev in
  let next =
    if prev_n < ring_size then Array.append prev [| new_bar |]
    else
      let n = ring_size in
      let arr = Array.make n new_bar in
        Array.blit prev 1 arr 0 (n - 1) ;
        arr.(n - 1) <- new_bar ;
        arr in
    Atomic.set cell.ring next


let republish_index ~index ~table =
  let alist = KH.fold (fun (sym, iv) cell acc -> (sym, iv, cell.ring) :: acc) table [] in
    Atomic.set index alist


let evict_lru ~table ~active_keys =
  let oldest_key, _ts =
    KH.fold
      (fun k cell (ok, ots) ->
        if Int64.compare cell.last_event_ts_ns ots < 0 then (Some k, cell.last_event_ts_ns)
        else (ok, ots))
      table (None, Int64.max_int) in
    match oldest_key with
    | Some k ->
      KH.remove table k ;
      Atomic.set active_keys (KH.length table) ;
      Log.info (fun m ->
        let s, i = k in
          m "evicted (sym=%s, interval=%Ldns) [LRU]" s i)
    | None -> ()


let domain_main ~intervals_ns ~ring_size ~max_active_keys ~queue ~stop_flag ~index ~active_keys
  ~ticks_processed ~bars_emitted ~late_ticks =
  let table : cell KH.t = KH.create max_active_keys in
  let process_one ev =
    incr_atomic_int64 ticks_processed ;
    List.iter
      (fun interval ->
        let key = (ev.symbol, interval) in
        let cell =
          match KH.find_opt table key with
          | Some c -> c
          | None ->
            if KH.length table >= max_active_keys then evict_lru ~table ~active_keys ;
            let fresh =
              {
                builder = Bar_builder.create ~symbol:ev.symbol ~interval_ns:interval;
                ring = Atomic.make [||];
                last_event_ts_ns = ev.ts_ns;
              } in
              KH.add table key fresh ;
              republish_index ~index ~table ;
              Atomic.set active_keys (KH.length table) ;
              fresh in
          cell.last_event_ts_ns <- ev.ts_ns ;
          let pre_late = Bar_builder.late_tick_count cell.builder in
            (match Bar_builder.on_tick cell.builder ~ts:ev.ts_ns ~price:ev.price ~size:ev.size with
            | None -> ()
            | Some bar ->
              push_bar ~ring_size cell bar ;
              incr_atomic_int64 bars_emitted) ;
            if Bar_builder.late_tick_count cell.builder > pre_late then incr_atomic_int64 late_ticks)
      intervals_ns in
  let rec drain_until_empty () =
    match SPSCQueue.dequeue queue with
    | None -> ()
    | Some ev ->
      process_one ev ;
      drain_until_empty () in
  let rec loop () =
    if Atomic.get stop_flag then drain_until_empty ()
    else
      match SPSCQueue.dequeue queue with
      | Some ev ->
        process_one ev ;
        loop ()
      | None ->
        Domain.cpu_relax () ;
        loop () in
    try loop ()
    with exn -> Log.err (fun m -> m "time_series domain crashed: %s" (Printexc.to_string exn))


let start ~bus ?(intervals_ns = [ 1_000_000_000L ]) ?(ring_size = 1024) ?(max_active_keys = 256) ()
    =
  let queue = SPSCQueue.create ~capacity:65_536 in
  let stop_flag = Atomic.make false in
  let joined = Atomic.make false in
  let index = Atomic.make [] in
  let active_keys = Atomic.make 0 in
  let ticks_observed = Atomic.make 0L in
  let ticks_processed = Atomic.make 0L in
  let ticks_rejected_sanity = Atomic.make 0L in
  let ticks_dropped_full_queue = Atomic.make 0L in
  let bars_emitted = Atomic.make 0L in
  let late_ticks = Atomic.make 0L in
  let handler (ev : Event_types.Event.t) =
    incr_atomic_int64 ticks_observed ;
    match payload_to_tick ev.payload with
    | None -> ()
    | Some te ->
      (match Filters.Sanity.check ~price:te.price ~size:te.size with
      | Filters.Sanity.Reject _ -> incr_atomic_int64 ticks_rejected_sanity
      | Filters.Sanity.Ok ->
        if not (SPSCQueue.enqueue queue te) then incr_atomic_int64 ticks_dropped_full_queue) in
  let subscription_id = Event_bus.subscribe_filtered bus (make_filter ()) handler in
  let domain =
    Domain.spawn (fun () ->
      Algostream_common_utils.Affinity.claim ~name:"time_series.drain" ;
      domain_main ~intervals_ns ~ring_size ~max_active_keys ~queue ~stop_flag ~index ~active_keys
        ~ticks_processed ~bars_emitted ~late_ticks) in
    {
      bus;
      intervals_ns;
      ring_size;
      max_active_keys;
      queue;
      stop_flag;
      joined;
      domain;
      subscription_id;
      ticks_observed;
      ticks_processed;
      ticks_rejected_sanity;
      ticks_dropped_full_queue;
      bars_emitted;
      late_ticks;
      active_keys;
      index;
    }


let stop t =
  if Atomic.compare_and_set t.joined false true then (
    Event_bus.unsubscribe t.bus t.subscription_id ;
    Atomic.set t.stop_flag true ;
    try Domain.join t.domain with _ -> ())


let bars t ~symbol ~interval_ns =
  let alist = Atomic.get t.index in
    match
      List.find_opt (fun (s, i, _) -> String.equal s symbol && Int64.equal i interval_ns) alist
    with
    | None -> None
    | Some (_, _, atom) -> Some (Atomic.get atom)


(* The index is an immutable list republished on change, so this is race-free from any Domain. *)
let keys t = List.map (fun (s, i, _) -> (s, i)) (Atomic.get t.index)

let stats t =
  {
    ticks_observed = Atomic.get t.ticks_observed;
    ticks_processed = Atomic.get t.ticks_processed;
    ticks_rejected_sanity = Atomic.get t.ticks_rejected_sanity;
    ticks_dropped_full_queue = Atomic.get t.ticks_dropped_full_queue;
    bars_emitted = Atomic.get t.bars_emitted;
    late_ticks = Atomic.get t.late_ticks;
    active_keys = Atomic.get t.active_keys;
  }


let is_running t = not (Atomic.get t.joined)
