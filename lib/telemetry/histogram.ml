(* Bucketing scheme, following HdrHistogram.

   For a value v, let e = floor(log2 v). Values below 2^sub_bits get one bucket each — at that
   magnitude the mantissa is the whole number, so the histogram is exact. Above that, the bucket is
   (e - sub_bits + 1) octaves in, offset by the top [sub_bits] bits of the mantissa.

   The result is constant relative error above the linear region and zero error inside it, with a
   fixed array and no allocation on the recording path. *)

let sub_bits = 4

let sub_count = 1 lsl sub_bits

(* Ceiling of 2^40 ns ~ 18.3 minutes. Anything slower than that is not a latency. *)
let max_exponent = 40

let n_buckets = ((max_exponent - sub_bits) * sub_count) + sub_count

type t = {
  buckets : int Atomic.t array;
  total : int Atomic.t;
  sum : int Atomic.t;
  (* Samples refused for being negative. See [record]. *)
  rejected : int Atomic.t;
  max : int Atomic.t;
}

let create () =
  {
    buckets = Array.init n_buckets (fun _ -> Atomic.make 0);
    total = Atomic.make 0;
    sum = Atomic.make 0;
    rejected = Atomic.make 0;
    max = Atomic.make 0;
  }


(* floor(log2 v) for v > 0, by binary reduction — six comparisons, no loop over 64 bits. *)
let highest_bit v =
  let v = ref v and n = ref 0 in
    if !v land 0x7FFFFFFF00000000 <> 0 then (
      v := !v lsr 32 ;
      n := !n + 32) ;
    if !v land 0xFFFF0000 <> 0 then (
      v := !v lsr 16 ;
      n := !n + 16) ;
    if !v land 0xFF00 <> 0 then (
      v := !v lsr 8 ;
      n := !n + 8) ;
    if !v land 0xF0 <> 0 then (
      v := !v lsr 4 ;
      n := !n + 4) ;
    if !v land 0xC <> 0 then (
      v := !v lsr 2 ;
      n := !n + 2) ;
    if !v land 0x2 <> 0 then n := !n + 1 ;
    !n


let bucket_of_value v =
  if v < sub_count then v
  else
    let e = highest_bit v in
      if e >= max_exponent then n_buckets - 1
      else
        (* shift = e - sub_bits, so [v lsr shift] lands in [sub_count, 2*sub_count) and the mask
           yields all [sub_count] distinct sub-buckets. Using [e - sub_bits + 1] instead would put
           it in [sub_count/2, sub_count), reaching only half of them and halving the resolution. *)
        let shift = e - sub_bits in
        let mantissa = (v lsr shift) land (sub_count - 1) in
          (shift * sub_count) + sub_count + mantissa


(* Upper bound of the values that fall in [b] — what [percentile] reports.

   Inverse of [bucket_of_value]. Above the linear region [v lsr shift = sub_count + mantissa], so
   the bucket covers [(sub_count + mantissa) lsl shift, (sub_count + mantissa + 1) lsl shift). Its
   width relative to its own floor is therefore [1 / (sub_count + mantissa)] — at worst [1 /
   sub_count]. *)
let bucket_upper_bound b =
  if b < sub_count then Int64.of_int b
  else
    let shift = (b - sub_count) / sub_count in
    let mantissa = (b - sub_count) mod sub_count in
      Int64.of_int (((sub_count + mantissa + 1) lsl shift) - 1)


let rec bump_max a v =
  let cur = Atomic.get a in
    if v <= cur then () else if Atomic.compare_and_set a cur v then () else bump_max a v


let record t ns =
  (* A negative duration is a caller bug — timestamps subtracted the wrong way round, or measured
     with a clock that stepped backwards. Folding it into bucket zero would silently improve the
     percentiles, so it is refused.

     But refusing it silently is how a real bug hid here: latency was measured against a wall clock,
     an NTP step produced negatives, and the samples simply vanished from the distribution with
     nothing to show for it. The count makes that visible — see {!rejected}. *)
  if Int64.compare ns 0L >= 0 then (
    let v = Int64.to_int ns in
      Atomic.incr t.buckets.(bucket_of_value v) ;
      Atomic.incr t.total ;
      ignore (Atomic.fetch_and_add t.sum v : int) ;
      bump_max t.max v)
  else Atomic.incr t.rejected


let count t = Int64.of_int (Atomic.get t.total)

let sum t = Int64.of_int (Atomic.get t.sum)

let rejected t = Int64.of_int (Atomic.get t.rejected)

let max t = Int64.of_int (Atomic.get t.max)

let mean t =
  let n = Atomic.get t.total in
    if n = 0 then 0.0 else float_of_int (Atomic.get t.sum) /. float_of_int n


let percentile t p =
  if Float.is_nan p || p < 0.0 || p > 100.0 then
    invalid_arg "Histogram.percentile: p must be in [0, 100]" ;
  let n = Atomic.get t.total in
    if n = 0 then 0L
    else
      (* Rank of the sample we want, 1-based. ceil so that p=100 selects the last sample and p=0
         selects the first. *)
      let target = Stdlib.max 1 (int_of_float (Float.ceil (p /. 100.0 *. float_of_int n))) in
      (* Clamp to the exact maximum. The bucket's upper bound can sit above every sample that
         actually landed in it, and a percentile that exceeds the largest observed value is both
         wrong and confusing on a chart. [max] is tracked exactly, so clamping only ever moves the
         answer towards a value that was really seen. *)
      let ceiling = Int64.of_int (Atomic.get t.max) in
      let clamp v = if Int64.compare v ceiling > 0 then ceiling else v in
      let rec scan i acc =
        if i >= n_buckets then ceiling
        else
          let acc = acc + Atomic.get t.buckets.(i) in
            if acc >= target then clamp (bucket_upper_bound i) else scan (i + 1) acc in
        scan 0 0


let count_at_or_above t threshold =
  if Int64.compare threshold 0L <= 0 then count t
  else
    let first = bucket_of_value (Int64.to_int threshold) in
    let total = ref 0 in
      for i = first to n_buckets - 1 do
        total := !total + Atomic.get t.buckets.(i)
      done ;
      Int64.of_int !total


let reset t =
  Array.iter (fun a -> Atomic.set a 0) t.buckets ;
  Atomic.set t.total 0 ;
  Atomic.set t.sum 0 ;
  Atomic.set t.rejected 0 ;
  Atomic.set t.max 0


type summary = {
  count : int64;
  mean_ns : float;
  p50_ns : int64;
  p90_ns : int64;
  p99_ns : int64;
  p999_ns : int64;
  max_ns : int64;
}

let empty_summary =
  { count = 0L; mean_ns = 0.0; p50_ns = 0L; p90_ns = 0L; p99_ns = 0L; p999_ns = 0L; max_ns = 0L }


let summary t =
  {
    count = count t;
    mean_ns = mean t;
    p50_ns = percentile t 50.0;
    p90_ns = percentile t 90.0;
    p99_ns = percentile t 99.0;
    p999_ns = percentile t 99.9;
    max_ns = max t;
  }


let summary_to_string s =
  Printf.sprintf "n=%Ld mean=%.0fns p50=%Ldns p90=%Ldns p99=%Ldns p99.9=%Ldns max=%Ldns" s.count
    s.mean_ns s.p50_ns s.p90_ns s.p99_ns s.p999_ns s.max_ns
