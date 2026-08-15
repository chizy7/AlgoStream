(** Lock-free data structures for ultra-low latency trading *)

open Base

(** Lock-free atomic operations module *)
module Atomic = struct
  type 'a t = 'a Atomic.t

  let create = Atomic.make

  let get = Atomic.get

  let set = Atomic.set

  let compare_and_set = Atomic.compare_and_set

  let fetch_and_add = Atomic.fetch_and_add

  let incr = Atomic.incr

  let decr = Atomic.decr
end

(** Lock-free ring buffer for high-frequency market data *)
module RingBuffer = struct
  type 'a t = {
    buffer : 'a array;
    capacity : int;
    head : int Atomic.t;
    tail : int Atomic.t;
    mask : int;
  }

  exception Buffer_full

  exception Buffer_empty

  let create ~capacity default_value =
    (* Ensure capacity is power of 2 for efficient modulo operations *)
    let power_of_2_capacity =
      let rec find_power_of_2 n acc = if acc >= n then acc else find_power_of_2 n (acc * 2) in
        find_power_of_2 capacity 1 in
      {
        buffer = Array.create ~len:power_of_2_capacity default_value;
        capacity = power_of_2_capacity;
        head = Atomic.create 0;
        tail = Atomic.create 0;
        mask = power_of_2_capacity - 1;
      }


  let size t =
    let head = Atomic.get t.head in
    let tail = Atomic.get t.tail in
      (tail - head) land t.mask


  let is_empty t = size t = 0

  let is_full t = size t = t.capacity - 1

  let rec push t item =
    let current_tail = Atomic.get t.tail in
    let next_tail = (current_tail + 1) land t.mask in
    let current_head = Atomic.get t.head in

    if next_tail = current_head then raise Buffer_full
    else (
      t.buffer.(current_tail) <- item ;
      (* Memory barrier to ensure write completes before updating tail *)
      if not (Atomic.compare_and_set t.tail current_tail next_tail) then
        (* Retry if another thread modified tail *)
        push t item)


  let rec pop t =
    let current_head = Atomic.get t.head in
    let current_tail = Atomic.get t.tail in

    if current_head = current_tail then raise Buffer_empty
    else
      let item = t.buffer.(current_head) in
      let next_head = (current_head + 1) land t.mask in
        if not (Atomic.compare_and_set t.head current_head next_head) then
          (* Retry if another thread modified head *)
          pop t
        else item


  let try_push t item =
    try
      push t item ;
      true
    with Buffer_full -> false


  let try_pop t = try Some (pop t) with Buffer_empty -> None
end

(** Lock-free single-producer, single-consumer queue *)
module SPSCQueue = struct
  type 'a t = {
    buffer : 'a option array;
    capacity : int;
    head : int Atomic.t;
    tail : int Atomic.t;
    mask : int;
  }

  let create ~capacity =
    let power_of_2_capacity =
      let rec find_power_of_2 n acc = if acc >= n then acc else find_power_of_2 n (acc * 2) in
        find_power_of_2 capacity 1 in
      {
        buffer = Array.create ~len:power_of_2_capacity None;
        capacity = power_of_2_capacity;
        head = Atomic.create 0;
        tail = Atomic.create 0;
        mask = power_of_2_capacity - 1;
      }


  let enqueue t item =
    let tail_pos = Atomic.get t.tail in
    let next_tail = (tail_pos + 1) land t.mask in

    if next_tail = Atomic.get t.head then false (* Queue is full *)
    else (
      t.buffer.(tail_pos) <- Some item ;
      Atomic.set t.tail next_tail ;
      true)


  let dequeue t =
    let head_pos = Atomic.get t.head in

    if head_pos = Atomic.get t.tail then None (* Queue is empty *)
    else
      match t.buffer.(head_pos) with
      | None -> None
      | Some item ->
        t.buffer.(head_pos) <- None ;
        Atomic.set t.head ((head_pos + 1) land t.mask) ;
        Some item
end

(** Lock-free stack for order management *)
module LockFreeStack = struct
  type 'a node = {
    data : 'a;
    next : 'a node option Atomic.t;
  }

  type 'a t = 'a node option Atomic.t

  let create () = Atomic.create None

  let push stack item =
    let new_node = { data = item; next = Atomic.create None } in
    let rec loop () =
      let current_top = Atomic.get stack in
        Atomic.set new_node.next current_top ;
        if not (Atomic.compare_and_set stack current_top (Some new_node)) then loop () in
      loop ()


  let pop stack =
    let rec loop () =
      match Atomic.get stack with
      | None -> None
      | Some node ->
        let next_node = Atomic.get node.next in
          if Atomic.compare_and_set stack (Some node) next_node then Some node.data else loop ()
    in
      loop ()


  let is_empty stack = match Atomic.get stack with None -> true | Some _ -> false
end

(** Lock-free hash table for order book levels *)
module LockFreeHashTable = struct
  type ('k, 'v) bucket = {
    key : 'k;
    value : 'v Atomic.t;
    next : ('k, 'v) bucket option Atomic.t;
  }

  type ('k, 'v) t = {
    buckets : ('k, 'v) bucket option Atomic.t array;
    size : int;
    hash_fn : 'k -> int;
    eq_fn : 'k -> 'k -> bool;
  }

  let create ~size ~hash_fn ~eq_fn =
    { buckets = Array.create ~len:size (Atomic.create None); size; hash_fn; eq_fn }


  let get_bucket_index t key = t.hash_fn key % t.size

  let rec find_in_bucket bucket key eq_fn =
    match bucket with
    | None -> None
    | Some node ->
      if eq_fn node.key key then Some (Atomic.get node.value)
      else find_in_bucket (Atomic.get node.next) key eq_fn


  let get t key =
    let bucket_index = get_bucket_index t key in
    let bucket = Atomic.get t.buckets.(bucket_index) in
      find_in_bucket bucket key t.eq_fn


  let put t key value =
    let bucket_index = get_bucket_index t key in
    let bucket_atomic = t.buckets.(bucket_index) in

    let rec update_or_insert current_bucket =
      match current_bucket with
      | None ->
        (* Create new bucket *)
        let new_bucket = { key; value = Atomic.create value; next = Atomic.create None } in
          if Atomic.compare_and_set bucket_atomic None (Some new_bucket) then true
          else
            (* Retry if bucket was modified *)
            update_or_insert (Atomic.get bucket_atomic)
      | Some node ->
        if t.eq_fn node.key key then (
          (* Update existing value *)
          Atomic.set node.value value ;
          true)
        else
          (* Continue searching *)
          update_or_insert (Atomic.get node.next) in
      update_or_insert (Atomic.get bucket_atomic)
end

(** Lock-free order book data structure *)
module OrderBook = struct
  type price = float

  type quantity = float

  type order_level = {
    price : price;
    quantity : quantity Atomic.t;
    order_count : int Atomic.t;
  }

  type side =
    | Bid
    | Ask

  type t = {
    bids : (price, order_level) LockFreeHashTable.t;
    asks : (price, order_level) LockFreeHashTable.t;
    best_bid : price option Atomic.t;
    best_ask : price option Atomic.t;
    sequence : int64 Atomic.t;
  }

  let price_hash = Float.hash

  let price_equal = Float.equal

  let create ~table_size =
    {
      bids = LockFreeHashTable.create ~size:table_size ~hash_fn:price_hash ~eq_fn:price_equal;
      asks = LockFreeHashTable.create ~size:table_size ~hash_fn:price_hash ~eq_fn:price_equal;
      best_bid = Atomic.create None;
      best_ask = Atomic.create None;
      sequence = Atomic.create 0L;
    }


  let add_order t side price quantity =
    let table = match side with Bid -> t.bids | Ask -> t.asks in
    let old_seq = Atomic.get t.sequence in
    let _ = Atomic.compare_and_set t.sequence old_seq Int64.(old_seq + 1L) in

    match LockFreeHashTable.get table price with
    | Some existing_level ->
      let old_quantity = Atomic.get existing_level.quantity in
      let _ =
        Atomic.compare_and_set existing_level.quantity old_quantity (old_quantity +. quantity) in
      let _ = Atomic.incr existing_level.order_count in
        ()
    | None ->
      let new_level = { price; quantity = Atomic.create quantity; order_count = Atomic.create 1 } in
      let _ = LockFreeHashTable.put table price new_level in
        (* Update best bid/ask *)
        (match side with
        | Bid ->
          let current_best = Atomic.get t.best_bid in
            (match current_best with
            | None -> Atomic.set t.best_bid (Some price)
            | Some current_price when Float.(price > current_price) ->
              Atomic.set t.best_bid (Some price)
            | _ -> ())
        | Ask ->
          let current_best = Atomic.get t.best_ask in
            (match current_best with
            | None -> Atomic.set t.best_ask (Some price)
            | Some current_price when Float.(price < current_price) ->
              Atomic.set t.best_ask (Some price)
            | _ -> ()))


  let get_best_bid t = Atomic.get t.best_bid

  let get_best_ask t = Atomic.get t.best_ask

  let get_spread t =
    match (get_best_bid t, get_best_ask t) with
    | Some bid, Some ask -> Some (ask -. bid)
    | _ -> None


  let get_midprice t =
    match (get_best_bid t, get_best_ask t) with
    | Some bid, Some ask -> Some ((bid +. ask) /. 2.0)
    | _ -> None
end

(** Performance monitoring for lock-free structures *)
module Metrics = struct
  type operation_metrics = {
    operation_count : int64 Atomic.t;
    total_latency_ns : int64 Atomic.t;
    max_latency_ns : int64 Atomic.t;
    contentions : int64 Atomic.t;
  }

  type operation_stats = {
    operation_count : int64;
    total_latency_ns : int64;
    max_latency_ns : int64;
    contentions : int64;
  }

  let create_metrics () : operation_metrics =
    {
      operation_count = Atomic.create 0L;
      total_latency_ns = Atomic.create 0L;
      max_latency_ns = Atomic.create 0L;
      contentions = Atomic.create 0L;
    }


  let record_operation (metrics : operation_metrics) latency_ns =
    let rec add_to_count () =
      let current = Atomic.get metrics.operation_count in
        if not (Atomic.compare_and_set metrics.operation_count current Int64.(current + 1L)) then
          add_to_count () in
    let rec add_to_total () =
      let current = Atomic.get metrics.total_latency_ns in
        if
          not (Atomic.compare_and_set metrics.total_latency_ns current Int64.(current + latency_ns))
        then add_to_total () in
      add_to_count () ;
      add_to_total () ;
      let current_max = Atomic.get metrics.max_latency_ns in
        if Int64.(latency_ns > current_max) then
          let _ = Atomic.compare_and_set metrics.max_latency_ns current_max latency_ns in
            ()


  let record_contention (metrics : operation_metrics) =
    let rec add_to_contentions () =
      let current = Atomic.get metrics.contentions in
        if not (Atomic.compare_and_set metrics.contentions current Int64.(current + 1L)) then
          add_to_contentions () in
      add_to_contentions ()


  let get_avg_latency_ns (metrics : operation_metrics) =
    let count = Atomic.get metrics.operation_count in
    let total = Atomic.get metrics.total_latency_ns in
      if Int64.(count > 0L) then Int64.(total / count) else 0L


  let get_stats (metrics : operation_metrics) =
    ({
       operation_count = Atomic.get metrics.operation_count;
       total_latency_ns = Atomic.get metrics.total_latency_ns;
       max_latency_ns = Atomic.get metrics.max_latency_ns;
       contentions = Atomic.get metrics.contentions;
     }
      : operation_stats)
end
