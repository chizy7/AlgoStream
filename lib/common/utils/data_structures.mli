(** Lock-free data structures for ultra-low latency trading *)

(** Lock-free atomic operations module *)
module Atomic : sig
  type 'a t

  val create : 'a -> 'a t

  val get : 'a t -> 'a

  val set : 'a t -> 'a -> unit

  val compare_and_set : 'a t -> 'a -> 'a -> bool

  val fetch_and_add : int t -> int -> int

  val incr : int t -> unit

  val decr : int t -> unit
end

(** Lock-free ring buffer for high-frequency market data *)
module RingBuffer : sig
  type 'a t

  exception Buffer_full

  exception Buffer_empty

  val create : capacity:int -> 'a -> 'a t

  val size : 'a t -> int

  val is_empty : 'a t -> bool

  val is_full : 'a t -> bool

  val push : 'a t -> 'a -> unit

  val pop : 'a t -> 'a

  val try_push : 'a t -> 'a -> bool

  val try_pop : 'a t -> 'a option
end

(** Lock-free single-producer, single-consumer queue *)
module SPSCQueue : sig
  type 'a t

  val create : capacity:int -> 'a t

  val enqueue : 'a t -> 'a -> bool

  val dequeue : 'a t -> 'a option
end

(** Lock-free stack for order management *)
module LockFreeStack : sig
  type 'a t

  val create : unit -> 'a t

  val push : 'a t -> 'a -> unit

  val pop : 'a t -> 'a option

  val is_empty : 'a t -> bool
end

(** Lock-free hash table for order book levels *)
module LockFreeHashTable : sig
  type ('k, 'v) t

  val create : size:int -> hash_fn:('k -> int) -> eq_fn:('k -> 'k -> bool) -> ('k, 'v) t

  val get : ('k, 'v) t -> 'k -> 'v option

  val put : ('k, 'v) t -> 'k -> 'v -> bool
end

(** Lock-free order book data structure *)
module OrderBook : sig
  type price = float

  type quantity = float

  type side =
    | Bid
    | Ask

  type t

  val create : table_size:int -> t

  val add_order : t -> side -> price -> quantity -> unit

  val get_best_bid : t -> price option

  val get_best_ask : t -> price option

  val get_spread : t -> price option

  val get_midprice : t -> price option
end

(** Performance monitoring for lock-free structures *)
module Metrics : sig
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

  val create_metrics : unit -> operation_metrics

  val record_operation : operation_metrics -> int64 -> unit

  val record_contention : operation_metrics -> unit

  val get_avg_latency_ns : operation_metrics -> int64

  val get_stats : operation_metrics -> operation_stats
end
