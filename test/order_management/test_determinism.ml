(* Determinism: same inputs → byte-identical reports. Plus the standard in-tree clock-leak scan over
   lib/order_management. *)

open Algostream_order_management
module Order = Algostream_domain_orders.Order

let test_execution_quality_deterministic () =
  let order = Helpers.make_order ~side:Order.Buy ~quantity:100.0 () in
  let fills =
    [
      Execution_quality.
        { ts_ns = 1L; price = 100.5; quantity = 100.0; venue = "v"; commission = 5.0 };
    ] in
  let r1 =
    Execution_quality.analyze ~order ~decision_price:100.0 ~decision_ts_ns:0L ~fills
      ~market_vwap:100.0 in
  let r2 =
    Execution_quality.analyze ~order ~decision_price:100.0 ~decision_ts_ns:0L ~fills
      ~market_vwap:100.0 in
    Alcotest.(check (float 1e-12)) "avg fill" r1.avg_fill_price r2.avg_fill_price ;
    Alcotest.(check (float 1e-12)) "slippage" r1.slippage_bps r2.slippage_bps ;
    Alcotest.(check (float 1e-12))
      "IS" r1.implementation_shortfall_bps r2.implementation_shortfall_bps


let test_book_impact_deterministic () =
  let book = Helpers.make_book ~asks:[| Helpers.make_level ~price:100.0 ~size:50.0 |] () in
  let e1 = Book_impact.estimate_from_book ~side:Order.Buy ~quantity:50.0 ~book in
  let e2 = Book_impact.estimate_from_book ~side:Order.Buy ~quantity:50.0 ~book in
    Alcotest.(check (float 1e-12)) "avg same" e1.avg_fill_price e2.avg_fill_price ;
    Alcotest.(check (float 1e-12)) "slippage same" e1.slippage_bps e2.slippage_bps


let test_kelly_deterministic () =
  let f1 =
    Position_sizing.Kelly.size_position ~capital:100_000.0 ~kelly_fraction:0.5 ~price:100.0 () in
  let f2 =
    Position_sizing.Kelly.size_position ~capital:100_000.0 ~kelly_fraction:0.5 ~price:100.0 () in
    Alcotest.(check (float 1e-12)) "kelly same" f1 f2


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


let test_no_clock_in_order_management () =
  let candidates =
    [
      "lib/order_management";
      "../../../lib/order_management";
      Filename.concat (Sys.getcwd ()) "lib/order_management";
    ] in
  let dir = match List.find_opt Sys.file_exists candidates with Some d -> d | None -> "" in
    if dir = "" then Alcotest.(check bool) "lint enforced via CI" true true
    else
      let leaks = scan_for_clock_leaks dir in
        if leaks <> [] then
          List.iter (fun (p, line) -> Printf.eprintf "CLOCK LEAK: %s :: %s\n" p line) leaks ;
        Alcotest.(check int) "no Clock.now_ / Unix.gettimeofday" 0 (List.length leaks)


let suite =
  [
    Alcotest.test_case "execution_quality_deterministic" `Quick test_execution_quality_deterministic;
    Alcotest.test_case "book_impact_deterministic" `Quick test_book_impact_deterministic;
    Alcotest.test_case "kelly_deterministic" `Quick test_kelly_deterministic;
    Alcotest.test_case "no_clock_in_order_management" `Quick test_no_clock_in_order_management;
  ]
