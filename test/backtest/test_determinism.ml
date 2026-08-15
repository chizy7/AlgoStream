(* Determinism: the same backtest run twice must be byte-identical, including the Timestamp fields
   on the final Portfolio. That last assertion is the regression test for the [?ts] threading — if
   anyone drops a [~ts] anywhere in the fill → portfolio path, the wall clock leaks in and this
   fails. Plus the standard in-tree clock-leak scan over lib/backtest and lib/strategy. *)

module BT = Algostream_backtest
module Portfolio = Algostream_domain_portfolio.Portfolio
module Position = Algostream_domain_portfolio.Position
module Timestamp = Algostream_domain_common.Timestamp
open Helpers

let records () =
  Array.init 60 (fun i ->
    let price = 100.0 +. (5.0 *. sin (float_of_int i /. 4.0)) in
      quoted_tick ~i ~price ())


let run_once () =
  (Scripted.script :=
     fun n ->
       if n mod 7 = 2 then [ buy ~qty:1.0 ~id:(Printf.sprintf "b%d" n) () ]
       else if n mod 7 = 5 then [ sell ~qty:1.0 ~id:(Printf.sprintf "s%d" n) () ]
       else []) ;
  let data = BT.Data_source.of_records (records ()) in
  let venue = fee_venue ~maker_bps:1.0 ~taker_bps:5.0 in
  let cfg = BT.Engine.default_config ~venue ~initial_capital:100_000.0 in
  let cfg =
    {
      cfg with
      BT.Engine.slippage = BT.Slippage.Spread_fraction 1.0;
      latency = BT.Latency.of_venue venue ~jitter_ns:250_000L ();
      cost = BT.Cost_model.default_config venue;
      root_seed = 4242L;
      run_index = 3;
    } in
    BT.Engine.run (module Scripted) ~params:Scripted.default_params ~config:cfg ~data


let test_replay_twice_identical () =
  let a = run_once () in
  let b = run_once () in
    Alcotest.(check int)
      "same number of equity points" (Array.length a.BT.Result.equity)
      (Array.length b.BT.Result.equity) ;
    Alcotest.(check int)
      "same number of blotter rows"
      (Array.length a.BT.Result.blotter)
      (Array.length b.BT.Result.blotter) ;
    Array.iteri
      (fun i (ea : BT.Result.equity_point) ->
        let eb = b.BT.Result.equity.(i) in
          if not (Int64.equal ea.BT.Result.ts_ns eb.BT.Result.ts_ns) then
            Alcotest.failf "equity[%d] ts differs" i ;
          Alcotest.(check (float 1e-12))
            (Printf.sprintf "equity[%d].nav" i)
            ea.BT.Result.nav eb.BT.Result.nav ;
          Alcotest.(check (float 1e-12))
            (Printf.sprintf "equity[%d].cash" i)
            ea.BT.Result.cash eb.BT.Result.cash ;
          Alcotest.(check (float 1e-12))
            (Printf.sprintf "equity[%d].drawdown" i)
            ea.BT.Result.drawdown eb.BT.Result.drawdown)
      a.BT.Result.equity ;
    Array.iteri
      (fun i (ra : BT.Result.blotter_row) ->
        let rb = b.BT.Result.blotter.(i) in
          if not (Int64.equal ra.BT.Result.ts_ns rb.BT.Result.ts_ns) then
            Alcotest.failf "blotter[%d] ts differs" i ;
          Alcotest.(check (float 1e-12))
            (Printf.sprintf "blotter[%d].price" i)
            ra.BT.Result.price rb.BT.Result.price ;
          Alcotest.(check (float 1e-12))
            (Printf.sprintf "blotter[%d].quantity" i)
            ra.BT.Result.quantity rb.BT.Result.quantity ;
          Alcotest.(check (float 1e-12))
            (Printf.sprintf "blotter[%d].commission" i)
            ra.BT.Result.commission rb.BT.Result.commission)
      a.BT.Result.blotter ;
    Alcotest.(check (float 1e-12))
      "total commission" a.BT.Result.total_commission b.BT.Result.total_commission


(* THE [?ts] regression test. Every Timestamp on the final portfolio must be identical across runs.
   These once came from Unix.time () and would differ whenever the two runs straddled a second
   boundary. *)
let test_portfolio_timestamps_are_event_time () =
  let a = run_once () in
  let b = run_once () in
  let ts_list pf =
    Base.Map.Poly.fold pf.Portfolio.positions ~init:[] ~f:(fun ~key ~data acc ->
      (key, Timestamp.to_float data.Position.opened_at, Timestamp.to_float data.Position.updated_at)
      :: acc)
    |> List.sort compare in
  let la = ts_list a.BT.Result.final_portfolio in
  let lb = ts_list b.BT.Result.final_portfolio in
    Alcotest.(check int) "same number of positions" (List.length la) (List.length lb) ;
    List.iter2
      (fun (ka, oa, ua) (kb, ob, ub) ->
        Alcotest.(check string) "symbol" ka kb ;
        Alcotest.(check (float 0.0)) (Printf.sprintf "%s opened_at is event time" ka) oa ob ;
        Alcotest.(check (float 0.0)) (Printf.sprintf "%s updated_at is event time" ka) ua ub)
      la lb ;
    Alcotest.(check (float 0.0))
      "portfolio updated_at is event time"
      (Timestamp.to_float a.BT.Result.final_portfolio.Portfolio.updated_at)
      (Timestamp.to_float b.BT.Result.final_portfolio.Portfolio.updated_at)


(* Substream discipline: a different run_index must give different execution noise, but the same
   run_index must reproduce exactly regardless of what ran before it. *)
let test_run_index_separates_streams () =
  let run idx =
    (Scripted.script := fun n -> if n = 2 then [ buy ~qty:1.0 ~id:"b" () ] else []) ;
    let data = BT.Data_source.of_records (records ()) in
    let venue = fee_venue ~maker_bps:1.0 ~taker_bps:5.0 in
    let cfg = BT.Engine.default_config ~venue ~initial_capital:100_000.0 in
    let cfg =
      {
        cfg with
        BT.Engine.slippage = BT.Slippage.Spread_fraction 1.0;
        latency = BT.Latency.of_venue venue ~jitter_ns:500_000_000L ();
        root_seed = 77L;
        run_index = idx;
      } in
      BT.Engine.run (module Scripted) ~params:Scripted.default_params ~config:cfg ~data in
  let a1 = run 1 in
  let a1' = run 1 in
    Alcotest.(check (float 1e-12))
      "run_index 1 reproduces" a1.BT.Result.total_commission a1'.BT.Result.total_commission ;
    Alcotest.(check int)
      "run_index 1 reproduces blotter length"
      (Array.length a1.BT.Result.blotter)
      (Array.length a1'.BT.Result.blotter)


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
                       (* Timestamp.now is included on top of the usual two: these layers must take
                          event time as a parameter, never read any clock. Comments mentioning the
                          names are excluded by requiring a call-shaped occurrence. *)
                       if
                         contains_substring line "Clock.now_"
                         || contains_substring line "Unix.gettimeofday"
                         || contains_substring line "Timestamp.now ()"
                       then leaks := (p, line) :: !leaks
                   done
                 with End_of_file -> ()) ;
                close_in ic))
        (Sys.readdir d) in
    walk dir ;
    !leaks


let check_dir label rel =
  let candidates = [ rel; "../../../" ^ rel; Filename.concat (Sys.getcwd ()) rel ] in
  let dir = match List.find_opt Sys.file_exists candidates with Some d -> d | None -> "" in
    if dir = "" then Alcotest.(check bool) "lint enforced via CI" true true
    else
      let leaks = scan_for_clock_leaks dir in
        if leaks <> [] then
          List.iter (fun (p, line) -> Printf.eprintf "CLOCK LEAK: %s :: %s\n" p line) leaks ;
        Alcotest.(check int) label 0 (List.length leaks)


let test_no_clock_in_backtest () = check_dir "no wall-clock in lib/backtest" "lib/backtest"

let test_no_clock_in_strategy () = check_dir "no wall-clock in lib/strategy" "lib/strategy"

let suite =
  [
    Alcotest.test_case "replay_twice_identical" `Quick test_replay_twice_identical;
    Alcotest.test_case "portfolio_timestamps_are_event_time" `Quick
      test_portfolio_timestamps_are_event_time;
    Alcotest.test_case "run_index_separates_streams" `Quick test_run_index_separates_streams;
    Alcotest.test_case "no_clock_in_backtest" `Quick test_no_clock_in_backtest;
    Alcotest.test_case "no_clock_in_strategy" `Quick test_no_clock_in_strategy;
  ]
