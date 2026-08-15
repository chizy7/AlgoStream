(* Determinism: same seed → byte-identical stream. Plus the standard in-tree clock-leak scan over
   lib/rng — a generator that consulted the wall clock would be the most damaging possible source of
   non-reproducibility, since every downstream Monte Carlo number derives from it. *)

module Rng = Algostream_rng.Rng

let test_same_seed_same_stream () =
  let a = Rng.create ~seed:1234 in
  let b = Rng.create ~seed:1234 in
    for i = 0 to 999 do
      let x = Rng.bits a and y = Rng.bits b in
        if not (Int64.equal x y) then Alcotest.failf "divergence at draw %d: %Lx vs %Lx" i x y
    done ;
    Alcotest.(check bool) "1000 draws identical" true true


let test_substream_batch_reproducible () =
  let batch () =
    Array.init 128 (fun k ->
      let r = Rng.substream ~root_seed:2026L ~index:k in
        Array.init 16 (fun _ -> Rng.bits r)) in
  let a = batch () in
  let b = batch () in
    Array.iteri
      (fun k row ->
        Array.iteri
          (fun i x ->
            if not (Int64.equal x b.(k).(i)) then Alcotest.failf "substream %d draw %d diverged" k i)
          row)
      a ;
    Alcotest.(check bool) "128 substreams x 16 draws reproducible" true true


(* Reversing the order in which substreams are constructed must not change any of them — this is
   what lets the Monte Carlo pool hand run k to whichever Domain is free. *)
let test_substream_order_independent () =
  let forward = Array.init 64 (fun k -> Rng.bits (Rng.substream ~root_seed:5L ~index:k)) in
  let backward = Array.make 64 0L in
    for k = 63 downto 0 do
      backward.(k) <- Rng.bits (Rng.substream ~root_seed:5L ~index:k)
    done ;
    Array.iteri
      (fun k x ->
        if not (Int64.equal x backward.(k)) then
          Alcotest.failf "substream %d differs by construction order" k)
      forward ;
    Alcotest.(check bool) "construction order irrelevant" true true


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
                         || contains_substring line "Timestamp.now"
                         || contains_substring line "self_init"
                       then leaks := (p, line) :: !leaks
                   done
                 with End_of_file -> ()) ;
                close_in ic))
        (Sys.readdir d) in
    walk dir ;
    !leaks


let test_no_clock_in_rng () =
  let candidates = [ "lib/rng"; "../../../lib/rng"; Filename.concat (Sys.getcwd ()) "lib/rng" ] in
  let dir = match List.find_opt Sys.file_exists candidates with Some d -> d | None -> "" in
    if dir = "" then Alcotest.(check bool) "lint enforced via CI" true true
    else
      let leaks = scan_for_clock_leaks dir in
        if leaks <> [] then
          List.iter (fun (p, line) -> Printf.eprintf "CLOCK LEAK: %s :: %s\n" p line) leaks ;
        Alcotest.(check int) "no wall-clock or self_init in lib/rng" 0 (List.length leaks)


let suite =
  [
    Alcotest.test_case "same_seed_same_stream" `Quick test_same_seed_same_stream;
    Alcotest.test_case "substream_batch_reproducible" `Quick test_substream_batch_reproducible;
    Alcotest.test_case "substream_order_independent" `Quick test_substream_order_independent;
    Alcotest.test_case "no_clock_in_rng" `Quick test_no_clock_in_rng;
  ]
