(** Writes a synthetic two-leg event log for backtesting demos and benchmarks.

    The two legs share a common factor and differ by a mean-reverting spread, so the pair is
    genuinely cointegrated and the reference strategy has something real to trade. Deterministic by
    construction — no RNG, no clock — so the docs' worked example reproduces exactly.

    Usage: gen_fixture [PATH] [N_BARS] *)

module EB = Algostream_infrastructure_event_bus
module W = EB.Event_log.Writer

let () =
  let path = if Array.length Sys.argv > 1 then Sys.argv.(1) else "/tmp/algostream_pair.log" in
  let n = if Array.length Sys.argv > 2 then int_of_string Sys.argv.(2) else 3000 in
  let w = W.create path in
    for i = 0 to n - 1 do
      let t = float_of_int i in
      (* Shared factor: a slow trend plus a faster cycle. *)
      let common = 30_000.0 +. (200.0 *. sin (t /. 90.0)) +. (40.0 *. sin (t /. 13.0)) in
      (* The tradable part: a mean-reverting spread on the y leg. *)
      let spread = 60.0 *. sin (t /. 25.0) in
      let y = common +. spread in
      let x = (common /. 15.0) +. (3.0 *. cos (t /. 40.0)) in
      let ts = Int64.mul (Int64.of_int i) 60_000_000_000L in
      let mk symbol price =
        EB.Event_types.Event.create ~source:"synthetic" ~priority:EB.Event_types.Priority.Normal
          (EB.Event_types.Event.Market_tick
             {
               symbol;
               timestamp_ns = ts;
               price;
               volume = 1.0;
               bid = price *. 0.9998;
               ask = price *. 1.0002;
             }) in
        W.append w (mk "BTCUSDT" y) ;
        W.append w (mk "ETHUSDT" x)
    done ;
    W.close w ;
    Printf.printf "wrote %s: %d events (%d bars x 2 legs)\n" path (2 * n) n
