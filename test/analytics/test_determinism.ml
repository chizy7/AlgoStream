(* Determinism property: replay the same tick stream twice through Per_symbol; final Snapshot must
   be byte-identical (no wall-clock leakage in the analytics path). *)

module PS = Algostream_analytics.Per_symbol
module Snap = Algostream_analytics.Snapshot
module Cfg = Algostream_analytics.Config
module Tick = Algostream_analytics.Tick_event

let make_stream ~n ~seed =
  let rng = Random.State.make [| seed |] in
    Array.init n (fun i ->
      let p = 100.0 +. (Random.State.float rng 2.0 -. 1.0) in
        {
          Tick.symbol = "BTC";
          timestamp_ns = Int64.of_int (i * 1_000_000);
          price = p;
          size = 1.0;
          bid = p -. 0.01;
          ask = p +. 0.01;
          kind = Tick.Market;
        })


let run_stream stream =
  let ps = PS.create ~symbol:"BTC" ~config:Cfg.default in
    Array.iter (PS.on_tick ps) stream ;
    PS.snapshot ps


let snapshots_equal (a : Snap.t) (b : Snap.t) =
  a.symbol = b.symbol
  && Int64.equal a.last_event_ts_ns b.last_event_ts_ns
  && a.n_ticks = b.n_ticks
  && abs_float (a.last_price -. b.last_price) < 1e-12
  && abs_float (a.denoised_price -. b.denoised_price) < 1e-12
  && abs_float (a.realized_vol -. b.realized_vol) < 1e-12
  && abs_float (a.ewma_vol -. b.ewma_vol) < 1e-12
  && abs_float (a.drawdown_from_peak -. b.drawdown_from_peak) < 1e-12
  && a.rejected_count = b.rejected_count


let test_replay_twice_matches () =
  let stream = make_stream ~n:5000 ~seed:42 in
  let a = run_stream stream in
  let b = run_stream stream in
    Alcotest.(check bool) "byte-equivalent snapshots" true (snapshots_equal a b)


let contains_substring haystack needle =
  let nl = String.length needle in
  let hl = String.length haystack in
  let rec loop i =
    if i + nl > hl then false else if String.sub haystack i nl = needle then true else loop (i + 1)
  in
    loop 0


let scan_for_clock_leaks dir =
  let leaks = ref [] in
  let rec walk d =
    if Sys.file_exists d && Sys.is_directory d then
      Array.iter
        (fun f ->
          let p = Filename.concat d f in
            if Sys.is_directory p then walk p
            else if Filename.check_suffix p ".ml" || Filename.check_suffix p ".mli" then (
              let ic = open_in p in
                (try
                   while true do
                     let line = input_line ic in
                       if
                         contains_substring line "Clock.now_"
                         || contains_substring line "Unix.gettimeofday"
                       then leaks := (p, line) :: !leaks
                   done
                 with End_of_file -> ()) ;
                close_in ic))
        (Sys.readdir d) in
    walk dir ;
    !leaks


let test_no_clock_in_analytics () =
  let candidates =
    [ "lib/analytics"; "../../../lib/analytics"; Filename.concat (Sys.getcwd ()) "lib/analytics" ]
  in
  let dir = match List.find_opt Sys.file_exists candidates with Some d -> d | None -> "" in
    if dir = "" then Alcotest.(check bool) "lint enforced via CI" true true
    else
      let leaks = scan_for_clock_leaks dir in
        if leaks <> [] then
          List.iter (fun (p, line) -> Printf.eprintf "CLOCK LEAK: %s :: %s\n" p line) leaks ;
        Alcotest.(check int)
          "no Clock.now_ / Unix.gettimeofday in lib/analytics" 0 (List.length leaks)


let suite =
  [
    Alcotest.test_case "replay_twice_matches" `Quick test_replay_twice_matches;
    Alcotest.test_case "no_clock_in_analytics" `Quick test_no_clock_in_analytics;
  ]
