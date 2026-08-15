module Venue = Algostream_order_management.Venue
module Rng = Algostream_rng.Rng

type t = {
  decision_to_venue_ns : int64;
  venue_match_ns : int64;
  fill_to_strategy_ns : int64;
  cancel_to_venue_ns : int64;
  jitter_ns : int64;
}

let zero =
  {
    decision_to_venue_ns = 0L;
    venue_match_ns = 0L;
    fill_to_strategy_ns = 0L;
    cancel_to_venue_ns = 0L;
    jitter_ns = 0L;
  }


let of_venue (v : Venue.t) ?(jitter_ns = 0L) () =
  let base = Int64.of_float (v.Venue.base_latency_us *. 1000.0) in
    {
      decision_to_venue_ns = base;
      (* Matching is fast relative to the network hop; dissemination back out is slower than the hop
         in. These ratios are conventional, not measured — override when you have real numbers. *)
      venue_match_ns = Int64.div base 4L;
      fill_to_strategy_ns = Int64.div base 2L;
      cancel_to_venue_ns = base;
      jitter_ns;
    }


let jittered base ~jitter ~rng =
  if Int64.compare jitter 0L <= 0 then base
  else
    let span = Int64.to_float (Int64.mul jitter 2L) in
    let offset = Int64.of_float ((Rng.uniform rng *. span) -. Int64.to_float jitter) in
    let v = Int64.add base offset in
      if Int64.compare v 0L < 0 then 0L else v


let outbound t ~rng =
  jittered (Int64.add t.decision_to_venue_ns t.venue_match_ns) ~jitter:t.jitter_ns ~rng


let inbound t ~rng = jittered t.fill_to_strategy_ns ~jitter:t.jitter_ns ~rng

let cancel t ~rng = jittered t.cancel_to_venue_ns ~jitter:t.jitter_ns ~rng

let to_string t =
  Printf.sprintf "out=%Ldns match=%Ldns in=%Ldns cancel=%Ldns jitter=±%Ldns" t.decision_to_venue_ns
    t.venue_match_ns t.fill_to_strategy_ns t.cancel_to_venue_ns t.jitter_ns
