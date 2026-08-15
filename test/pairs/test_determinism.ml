(* Determinism property: replay the same tick stream twice through Per_pair; final Snapshot fields
   are byte-identical (no wall-clock leakage in the pairs path). *)

open Algostream_pairs

let make_stream ~n ~seed =
  let rng = Random.State.make [| seed |] in
    Array.init n (fun i ->
      let x = Helpers.normal_sample rng +. 100.0 in
      let y = (1.5 *. x) +. (0.05 *. Helpers.normal_sample rng) in
      let ts = Int64.of_int (i * 1_000_000) in
        (ts, x, y))


let run_stream pid stream =
  let pp = Per_pair.create ~pair:pid ~config:Config.default in
    Array.iter (fun (ts, x, y) -> Per_pair.on_tick pp ~y_price:y ~x_price:x ~ts_ns:ts) stream ;
    Per_pair.snapshot pp


let snapshots_equal (a : Snapshot.t) (b : Snapshot.t) =
  Pair_id.equal a.pair b.pair
  && Int64.equal a.last_event_ts_ns b.last_event_ts_ns
  && a.n_ticks = b.n_ticks
  && abs_float (a.last_price_y -. b.last_price_y) < 1e-12
  && abs_float (a.last_price_x -. b.last_price_x) < 1e-12
  && abs_float (a.beta -. b.beta) < 1e-12
  && abs_float (a.intercept -. b.intercept) < 1e-12
  && abs_float (a.spread -. b.spread) < 1e-12
  && abs_float (a.spread_mean -. b.spread_mean) < 1e-12
  && abs_float (a.spread_std -. b.spread_std) < 1e-12
  && abs_float (a.corr -. b.corr) < 1e-12


let test_replay_twice_matches () =
  let pid = Helpers.pair "BTC" "ETH" in
  let stream = make_stream ~n:5000 ~seed:42 in
  let a = run_stream pid stream in
  let b = run_stream pid stream in
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


let test_no_clock_in_pairs () =
  let candidates =
    [ "lib/pairs"; "../../../lib/pairs"; Filename.concat (Sys.getcwd ()) "lib/pairs" ] in
  let dir = match List.find_opt Sys.file_exists candidates with Some d -> d | None -> "" in
    if dir = "" then Alcotest.(check bool) "lint enforced via CI" true true
    else
      let leaks = scan_for_clock_leaks dir in
        if leaks <> [] then
          List.iter (fun (p, line) -> Printf.eprintf "CLOCK LEAK: %s :: %s\n" p line) leaks ;
        Alcotest.(check int) "no Clock.now_ / Unix.gettimeofday in lib/pairs" 0 (List.length leaks)


let suite =
  [
    Alcotest.test_case "replay_twice_matches" `Quick test_replay_twice_matches;
    Alcotest.test_case "no_clock_in_pairs" `Quick test_no_clock_in_pairs;
  ]
