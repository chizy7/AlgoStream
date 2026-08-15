module Clock = Algostream_common_utils.Time_utils.Clock

type t = {
  clock_ns : unit -> int64;
  capacity : int;
  refill_per_sec : int;
  reserved_capacity : int;
  mutable tokens : float;
  mutable reserved_tokens : float;
  mutable last_refill_ns : int64;
}

let create ?(clock_ns = Clock.now_monotonic_ns) ~capacity ~refill_per_sec ~reserved () =
  {
    clock_ns;
    capacity;
    refill_per_sec;
    reserved_capacity = reserved;
    tokens = float_of_int capacity;
    reserved_tokens = float_of_int reserved;
    last_refill_ns = clock_ns ();
  }


let refill t =
  let now = t.clock_ns () in
  let elapsed_ns = Int64.sub now t.last_refill_ns in
    if Int64.compare elapsed_ns 0L > 0 then (
      let elapsed_s = Int64.to_float elapsed_ns /. 1_000_000_000.0 in
      let added = elapsed_s *. float_of_int t.refill_per_sec in
        t.tokens <- min (float_of_int t.capacity) (t.tokens +. added) ;
        t.reserved_tokens <- min (float_of_int t.reserved_capacity) (t.reserved_tokens +. added) ;
        t.last_refill_ns <- now)


let try_take ?(reserved = false) t =
  refill t ;
  if reserved && t.reserved_tokens >= 1.0 then (
    t.reserved_tokens <- t.reserved_tokens -. 1.0 ;
    true)
  else if t.tokens >= 1.0 then (
    t.tokens <- t.tokens -. 1.0 ;
    true)
  else false


let available t =
  refill t ;
  int_of_float t.tokens


let available_reserved t =
  refill t ;
  int_of_float t.reserved_tokens
