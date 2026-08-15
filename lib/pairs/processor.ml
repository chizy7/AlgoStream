module Event_bus = Algostream_infrastructure_event_bus.Event_bus
module Event_types = Algostream_infrastructure_event_bus.Event_types
module Subscription = Algostream_infrastructure_event_bus.Subscription
module SPSCQueue = Algostream_common_utils.Data_structures.SPSCQueue
module Tick_event = Algostream_analytics.Tick_event
module Bar = Algostream_time_series.Bar

let log_src = Logs.Src.create "algostream.pairs.processor"

module Log = (val Logs.src_log log_src : Logs.LOG)

type pair_spec = {
  pair : Pair_id.t;
  y_raw : string;
  x_raw : string;
}

type leg =
  | Leg_y
  | Leg_x

type pair_event =
  | Tick of {
      symbol : string;
      ts_ns : int64;
      price : float;
    }
  | Bar of Bar.t

type stats = {
  ticks_observed : int64;
  ticks_processed : int64;
  bars_processed : int64;
  ticks_dropped_full_queue : int64;
  out_of_order_drops : int64;
  active_pairs : int;
}

type t = {
  bus : Event_bus.t;
  config : Config.t;
  queue : pair_event SPSCQueue.t;
  stop_flag : bool Atomic.t;
  joined : bool Atomic.t;
  domain : unit Domain.t;
  subscription_id : Subscription.subscription_id;
  ticks_observed : int64 Atomic.t;
  ticks_processed : int64 Atomic.t;
  bars_processed : int64 Atomic.t;
  ticks_dropped_full_queue : int64 Atomic.t;
  out_of_order_drops : int64 Atomic.t;
  active_pairs : int Atomic.t;
  pairs_index : (Pair_id.t * Snapshot.t Atomic.t) list Atomic.t;
}

let incr_atomic_int64 a =
  let rec loop () =
    let cur = Atomic.get a in
    let next = Int64.add cur 1L in
      if Atomic.compare_and_set a cur next then () else loop () in
    loop ()


let make_filter () =
  let mt_market = Algostream_common_utils.Zero_copy.MessageType.market_data in
  let mt_trade = Algostream_common_utils.Zero_copy.MessageType.trade_execution in
    Subscription.Filter.or_
      (Subscription.Filter.by_message_type mt_market)
      (Subscription.Filter.by_message_type mt_trade)


let domain_main ~config ~queue ~stop_flag ~pairs_index ~active_pairs ~ticks_processed
  ~bars_processed ~out_of_order_drops ~pair_specs =
  let pair_table : (Pair_id.t, Per_pair.t) Hashtbl.t = Hashtbl.create 64 in
  let raw_to_pairs : (string, (Pair_id.t * leg) list) Hashtbl.t = Hashtbl.create 64 in
  let other_raw : (Pair_id.t * leg, string) Hashtbl.t = Hashtbl.create 64 in
  let price_cache : (string, float * int64) Hashtbl.t = Hashtbl.create 32 in
  let bar_cache : (string, Bar.t) Hashtbl.t = Hashtbl.create 32 in
    List.iter
      (fun (spec : pair_spec) ->
        let pp = Per_pair.create ~pair:spec.pair ~config in
          Hashtbl.replace pair_table spec.pair pp ;
          let add raw_sym which =
            let cur = try Hashtbl.find raw_to_pairs raw_sym with Not_found -> [] in
              Hashtbl.replace raw_to_pairs raw_sym ((spec.pair, which) :: cur) in
            add spec.y_raw Leg_y ;
            add spec.x_raw Leg_x ;
            Hashtbl.replace other_raw (spec.pair, Leg_y) spec.x_raw ;
            Hashtbl.replace other_raw (spec.pair, Leg_x) spec.y_raw)
      pair_specs ;
    let alist =
      Hashtbl.fold (fun pid pp acc -> (pid, Per_pair.snapshot_atomic pp) :: acc) pair_table [] in
      Atomic.set pairs_index alist ;
      Atomic.set active_pairs (Hashtbl.length pair_table) ;
      let max_stale = config.Config.max_price_staleness_ns in
      let process_tick ts_ns raw_sym price =
        incr_atomic_int64 ticks_processed ;
        Hashtbl.replace price_cache raw_sym (price, ts_ns) ;
        match Hashtbl.find_opt raw_to_pairs raw_sym with
        | None -> ()
        | Some legs ->
          List.iter
            (fun (pair_id, which) ->
              let pp = Hashtbl.find pair_table pair_id in
              let other = Hashtbl.find other_raw (pair_id, which) in
                match Hashtbl.find_opt price_cache other with
                | None -> ()
                | Some (other_price, other_ts) ->
                  let dt =
                    let d = Int64.sub ts_ns other_ts in
                      if Int64.compare d 0L < 0 then Int64.neg d else d in
                    if Int64.compare dt max_stale > 0 then ()
                    else
                      let y_price, x_price =
                        match which with
                        | Leg_y -> (price, other_price)
                        | Leg_x -> (other_price, price) in
                      let prev_ooo = Per_pair.out_of_order_count pp in
                        Per_pair.on_tick pp ~y_price ~x_price ~ts_ns ;
                        if Per_pair.out_of_order_count pp > prev_ooo then
                          incr_atomic_int64 out_of_order_drops)
            legs in
      let process_bar (b : Bar.t) =
        incr_atomic_int64 bars_processed ;
        Hashtbl.replace bar_cache b.symbol b ;
        match Hashtbl.find_opt raw_to_pairs b.symbol with
        | None -> ()
        | Some legs ->
          List.iter
            (fun (pair_id, which) ->
              let pp = Hashtbl.find pair_table pair_id in
              let other = Hashtbl.find other_raw (pair_id, which) in
                match Hashtbl.find_opt bar_cache other with
                | Some other_bar when Int64.equal other_bar.Bar.open_ts b.open_ts ->
                  let y_bar, x_bar =
                    match which with Leg_y -> (b, other_bar) | Leg_x -> (other_bar, b) in
                    Per_pair.on_bar pp ~y_bar ~x_bar
                | _ -> ())
            legs in
      let process_one = function
        | Tick { ts_ns; symbol; price } -> process_tick ts_ns symbol price
        | Bar b -> process_bar b in
      let rec drain () =
        match SPSCQueue.dequeue queue with
        | None -> ()
        | Some ev ->
          process_one ev ;
          drain () in
      let rec loop () =
        if Atomic.get stop_flag then drain ()
        else
          match SPSCQueue.dequeue queue with
          | Some ev ->
            process_one ev ;
            loop ()
          | None ->
            Domain.cpu_relax () ;
            loop () in
        try loop ()
        with exn -> Log.err (fun m -> m "pairs domain crashed: %s" (Printexc.to_string exn))


let start ~bus ~pairs ?(config = Config.default) () =
  let n = List.length pairs in
    if n > config.Config.max_active_pairs then
      invalid_arg
        (Printf.sprintf "Pairs.Processor.start: %d pairs exceeds max_active_pairs=%d" n
           config.max_active_pairs) ;
    let queue = SPSCQueue.create ~capacity:65_536 in
    let stop_flag = Atomic.make false in
    let joined = Atomic.make false in
    let pairs_index = Atomic.make [] in
    let active_pairs = Atomic.make 0 in
    let ticks_observed = Atomic.make 0L in
    let ticks_processed = Atomic.make 0L in
    let bars_processed = Atomic.make 0L in
    let ticks_dropped_full_queue = Atomic.make 0L in
    let out_of_order_drops = Atomic.make 0L in
    let interest = Hashtbl.create 32 in
      List.iter
        (fun (s : pair_spec) ->
          Hashtbl.replace interest s.y_raw () ;
          Hashtbl.replace interest s.x_raw ())
        pairs ;
      let handler (ev : Event_types.Event.t) =
        incr_atomic_int64 ticks_observed ;
        match Tick_event.of_event_payload ev.payload with
        | None -> ()
        | Some te ->
          if not (Hashtbl.mem interest te.symbol) then ()
          else
            let ok =
              SPSCQueue.enqueue queue
                (Tick { symbol = te.symbol; ts_ns = te.timestamp_ns; price = te.price }) in
              if not ok then incr_atomic_int64 ticks_dropped_full_queue in
      let subscription_id = Event_bus.subscribe_filtered bus (make_filter ()) handler in
      let domain =
        Domain.spawn (fun () ->
          Algostream_common_utils.Affinity.claim ~name:"pairs.drain" ;
          domain_main ~config ~queue ~stop_flag ~pairs_index ~active_pairs ~ticks_processed
            ~bars_processed ~out_of_order_drops ~pair_specs:pairs) in
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
          bars_processed;
          ticks_dropped_full_queue;
          out_of_order_drops;
          active_pairs;
          pairs_index;
        }


let stop t =
  if Atomic.compare_and_set t.joined false true then (
    Event_bus.unsubscribe t.bus t.subscription_id ;
    Atomic.set t.stop_flag true ;
    try Domain.join t.domain with _ -> ())


let snapshot t ~pair =
  let alist = Atomic.get t.pairs_index in
  let rec find = function
    | [] -> Snapshot.empty ~pair
    | (p, a) :: rest -> if Pair_id.equal p pair then Atomic.get a else find rest in
    find alist


let snapshots t =
  let alist = Atomic.get t.pairs_index in
    List.map (fun (_p, a) -> Atomic.get a) alist


let feed_bar t bar =
  if not (SPSCQueue.enqueue t.queue (Bar bar)) then incr_atomic_int64 t.ticks_dropped_full_queue


let stats t =
  {
    ticks_observed = Atomic.get t.ticks_observed;
    ticks_processed = Atomic.get t.ticks_processed;
    bars_processed = Atomic.get t.bars_processed;
    ticks_dropped_full_queue = Atomic.get t.ticks_dropped_full_queue;
    out_of_order_drops = Atomic.get t.out_of_order_drops;
    active_pairs = Atomic.get t.active_pairs;
  }


let is_running t = not (Atomic.get t.joined)
