module Event_bus = Algostream_infrastructure_event_bus.Event_bus
module Subscription = Algostream_infrastructure_event_bus.Subscription
module Event_types = Algostream_infrastructure_event_bus.Event_types
module SPSCQueue = Algostream_common_utils.Data_structures.SPSCQueue

let log_src = Logs.Src.create "algostream.analytics.processor"

module Log = (val Logs.src_log log_src : Logs.LOG)

type stats = {
  ticks_observed : int64;
  ticks_processed : int64;
  ticks_rejected_sanity : int64;
  ticks_rejected_outlier : int64;
  ticks_dropped_full_queue : int64;
  out_of_order_drops : int64;
  active_symbols : int;
  evictions : int64;
}

type t = {
  bus : Event_bus.t;
  config : Config.t;
  queue : Tick_event.t SPSCQueue.t;
  stop_flag : bool Atomic.t;
  joined : bool Atomic.t;
  domain : unit Domain.t;
  subscription_id : Subscription.subscription_id;
  ticks_observed : int64 Atomic.t;
  ticks_processed : int64 Atomic.t;
  ticks_rejected_sanity : int64 Atomic.t;
  ticks_rejected_outlier : int64 Atomic.t;
  ticks_dropped_full_queue : int64 Atomic.t;
  out_of_order_drops : int64 Atomic.t;
  evictions : int64 Atomic.t;
  active_symbols : int Atomic.t;
  symbols_index : (string * Snapshot.t Atomic.t) list Atomic.t;
}

let incr_atomic_int64 a =
  let rec loop () =
    let cur = Atomic.get a in
    let next = Int64.add cur 1L in
      if Atomic.compare_and_set a cur next then () else loop () in
    loop ()


let lookup_index_atomic t ~symbol =
  let alist = Atomic.get t.symbols_index in
    List.assoc_opt symbol alist


let snapshot t ~symbol =
  match lookup_index_atomic t ~symbol with
  | Some atom -> Atomic.get atom
  | None -> Snapshot.empty ~symbol


(* The index is republished as a whole immutable alist whenever the symbol set changes, so both of
   these are race-free reads from any Domain. *)
let symbols t = List.map fst (Atomic.get t.symbols_index)

let snapshots t = List.map (fun (_, atom) -> Atomic.get atom) (Atomic.get t.symbols_index)

(* Cross-symbol rolling correlation needs rolling statistics shared across a pair of symbols, which
   this processor does not maintain — each symbol's state is independent by design. Returns a
   documented 0.0 rather than a plausible-looking number; the dashboard deliberately does not render
   it. Pairs.Per_pair is where a real cross-symbol statistic lives. *)
let correlation _t ~a:_ ~b:_ = 0.0

let stats t =
  {
    ticks_observed = Atomic.get t.ticks_observed;
    ticks_processed = Atomic.get t.ticks_processed;
    ticks_rejected_sanity = Atomic.get t.ticks_rejected_sanity;
    ticks_rejected_outlier = Atomic.get t.ticks_rejected_outlier;
    ticks_dropped_full_queue = Atomic.get t.ticks_dropped_full_queue;
    out_of_order_drops = Atomic.get t.out_of_order_drops;
    active_symbols = Atomic.get t.active_symbols;
    evictions = Atomic.get t.evictions;
  }


let is_running t = not (Atomic.get t.joined)

(* ───── analytics domain main loop ─────────────────────────────────── *)

(* The drain loop captures only the primitive state it needs (queue + stop flag + index/atomics +
   config), not the whole [t] record. This keeps it independent of [t]'s construction order and
   eliminates the startup race that occurs when [Domain.spawn] schedules [domain_fn] before the
   parent finishes assembling [t]. *)

let republish_index ~symbols_index ~active_symbols ~table =
  let alist =
    Hashtbl.fold (fun sym ps acc -> (sym, Per_symbol.snapshot_atomic ps) :: acc) table [] in
    Atomic.set symbols_index alist ;
    Atomic.set active_symbols (Hashtbl.length table)


let evict_lru ~evictions ~table =
  let oldest_sym, _oldest_ts =
    Hashtbl.fold
      (fun sym ps (osym, ots) ->
        let ts = Per_symbol.last_event_ts_ns ps in
          if Int64.compare ts ots < 0 then (sym, ts) else (osym, ots))
      table ("", Int64.max_int) in
    if oldest_sym <> "" then (
      Hashtbl.remove table oldest_sym ;
      incr_atomic_int64 evictions ;
      Log.info (fun m -> m "evicted symbol %s (LRU)" oldest_sym))


let domain_main ~config ~queue ~stop_flag ~symbols_index ~active_symbols ~ticks_processed
  ~ticks_rejected_outlier ~out_of_order_drops ~evictions =
  let table : (string, Per_symbol.t) Hashtbl.t = Hashtbl.create config.Config.max_active_symbols in
  let process_one (ev : Tick_event.t) =
    incr_atomic_int64 ticks_processed ;
    let ps =
      match Hashtbl.find_opt table ev.symbol with
      | Some ps -> ps
      | None ->
        if Hashtbl.length table >= config.max_active_symbols then evict_lru ~evictions ~table ;
        let fresh = Per_symbol.create ~symbol:ev.symbol ~config in
          Hashtbl.add table ev.symbol fresh ;
          republish_index ~symbols_index ~active_symbols ~table ;
          fresh in
    let prev_ooo = Per_symbol.out_of_order_count ps in
    let prev_rej = Per_symbol.rejected_count ps in
      Per_symbol.on_tick ps ev ;
      if Per_symbol.out_of_order_count ps > prev_ooo then incr_atomic_int64 out_of_order_drops ;
      if Per_symbol.rejected_count ps > prev_rej then incr_atomic_int64 ticks_rejected_outlier in
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
    with exn -> Log.err (fun m -> m "analytics domain crashed: %s" (Printexc.to_string exn))


(* ───── start / stop ──────────────────────────────────────────────── *)

let make_filter () =
  let mt = Algostream_common_utils.Zero_copy.MessageType.market_data in
  let tt = Algostream_common_utils.Zero_copy.MessageType.trade_execution in
    Subscription.Filter.or_
      (Subscription.Filter.by_message_type mt)
      (Subscription.Filter.by_message_type tt)


let start ~bus ?(config = Config.default) () =
  let queue = SPSCQueue.create ~capacity:65_536 in
  let stop_flag = Atomic.make false in
  let joined = Atomic.make false in
  let symbols_index = Atomic.make [] in
  let active_symbols = Atomic.make 0 in
  let ticks_observed = Atomic.make 0L in
  let ticks_processed = Atomic.make 0L in
  let ticks_rejected_sanity = Atomic.make 0L in
  let ticks_rejected_outlier = Atomic.make 0L in
  let ticks_dropped_full_queue = Atomic.make 0L in
  let out_of_order_drops = Atomic.make 0L in
  let evictions = Atomic.make 0L in
  (* Bus shim subscriber: O(1), captures only [queue] + sanity counters. *)
  let handler (ev : Event_types.Event.t) =
    incr_atomic_int64 ticks_observed ;
    match Tick_event.of_event_payload ev.payload with
    | None -> ()
    | Some te ->
      (match Filters.Sanity.check ~price:te.price ~size:te.size with
      | Filters.Sanity.Reject _ -> incr_atomic_int64 ticks_rejected_sanity
      | Filters.Sanity.Ok ->
        if not (SPSCQueue.enqueue queue te) then incr_atomic_int64 ticks_dropped_full_queue) in
  let subscription_id = Event_bus.subscribe_filtered bus (make_filter ()) handler in
  (* Spawn the analytics Domain with a closure that captures only the primitive state it needs. No
     reference to [t] — eliminates the startup race where [Domain.spawn] could schedule the drain
     loop before [t] is assembled. *)
  let domain =
    Domain.spawn (fun () ->
      Algostream_common_utils.Affinity.claim ~name:"analytics.drain" ;
      domain_main ~config ~queue ~stop_flag ~symbols_index ~active_symbols ~ticks_processed
        ~ticks_rejected_outlier ~out_of_order_drops ~evictions) in
    {
      bus;
      config;
      queue;
      stop_flag;
      joined;
      domain;
      subscription_id;
      ticks_observed;
      ticks_processed;
      ticks_rejected_sanity;
      ticks_rejected_outlier;
      ticks_dropped_full_queue;
      out_of_order_drops;
      evictions;
      active_symbols;
      symbols_index;
    }


let stop t =
  if Atomic.compare_and_set t.joined false true then (
    Event_bus.unsubscribe t.bus t.subscription_id ;
    Atomic.set t.stop_flag true ;
    try Domain.join t.domain with _ -> ())
