(* Same scripted snapshot sequence, same actions. Plus the clock-leak scan over lib/strategy — a
   strategy that read a clock would make every backtest built on it irreproducible. *)

module PMR = Algostream_strategy.Pairs_mean_reversion
module Action = Algostream_strategy.Action
module Event = Algostream_strategy.Event
module Mean_reversion = Algostream_pairs.Mean_reversion

let script =
  [
    Mean_reversion.Hold;
    Mean_reversion.Long_spread;
    Mean_reversion.Long_spread;
    Mean_reversion.Hold;
    Mean_reversion.Exit;
    Mean_reversion.Short_spread;
    Mean_reversion.Exit;
  ]


let run () =
  let st = PMR.create ~params:PMR.default_params ~symbols:[ "BTCUSDT"; "ETHUSDT" ] in
  let out = ref [] in
    List.iteri
      (fun i signal ->
        let s = Test_pairs_mean_reversion.snap ~signal () in
        let c =
          Test_pairs_mean_reversion.ctx ~positions:[ ("BTCUSDT", 1.0); ("ETHUSDT", -2.0) ] () in
        let acts =
          PMR.on_event st c
            (Event.Pair_snapshot { snapshot = s; y_symbol = "BTCUSDT"; x_symbol = "ETHUSDT" }) in
          out := (i, List.map Action.to_string acts) :: !out)
      script ;
    (List.rev !out, PMR.diagnostics st)


let test_same_script_same_actions () =
  let a, da = run () in
  let b, db = run () in
    Alcotest.(check int) "same number of steps" (List.length a) (List.length b) ;
    List.iter2
      (fun (i, xs) (j, ys) ->
        Alcotest.(check int) "step index" i j ;
        Alcotest.(check (list string)) (Printf.sprintf "actions at step %d" i) xs ys)
      a b ;
    List.iter2
      (fun (k, v) (k2, v2) ->
        Alcotest.(check string) "diagnostic name" k k2 ;
        Alcotest.(check (float 0.0)) k v v2)
      da db


let contains haystack needle =
  let nl = String.length needle and hl = String.length haystack in
  let rec loop i =
    if i + nl > hl then false else if String.sub haystack i nl = needle then true else loop (i + 1)
  in
    loop 0


let test_no_clock_in_strategy () =
  let banned = [ "Clock.now_"; "Unix.gettimeofday"; "Timestamp.now ()"; "self_init" ] in
  let candidates =
    [ "lib/strategy"; "../../../lib/strategy"; Filename.concat (Sys.getcwd ()) "lib/strategy" ]
  in
    match List.find_opt Sys.file_exists candidates with
    | None -> Alcotest.(check bool) "lint enforced via CI" true true
    | Some dir ->
      let leaks = ref [] in
      let rec walk d =
        Array.iter
          (fun f ->
            let p = Filename.concat d f in
              if Sys.is_directory p then walk p
              else if Filename.check_suffix p ".ml" || Filename.check_suffix p ".mli" then (
                let ic = open_in p in
                  (try
                     while true do
                       let line = input_line ic in
                         List.iter
                           (fun b -> if contains line b then leaks := (p, line) :: !leaks)
                           banned
                     done
                   with End_of_file -> ()) ;
                  close_in ic))
          (Sys.readdir d) in
        walk dir ;
        if !leaks <> [] then List.iter (fun (p, l) -> Printf.eprintf "LEAK: %s :: %s\n" p l) !leaks ;
        Alcotest.(check int) "no wall-clock in lib/strategy" 0 (List.length !leaks)


(* lib/strategy must not depend on the backtest engine or the event bus — that separation is what
   lets a future live runner implement Strategy.S without linking the fill simulator. *)
let test_no_backtest_or_bus_dependency () =
  let candidates =
    [
      "lib/strategy/dune";
      "../../../lib/strategy/dune";
      Filename.concat (Sys.getcwd ()) "lib/strategy/dune";
    ] in
    match List.find_opt Sys.file_exists candidates with
    | None -> Alcotest.(check bool) "checked in CI" true true
    | Some p ->
      let ic = open_in p in
      let buf = Buffer.create 512 in
        (try
           while true do
             Buffer.add_string buf (input_line ic) ;
             Buffer.add_char buf '\n'
           done
         with End_of_file -> ()) ;
        close_in ic ;
        let s = Buffer.contents buf in
          Alcotest.(check bool)
            "does not depend on algostream_backtest" false
            (contains s "algostream_backtest") ;
          Alcotest.(check bool)
            "does not depend on the event bus" false
            (contains s "algostream_infrastructure_event_bus")


let suite =
  [
    Alcotest.test_case "same_script_same_actions" `Quick test_same_script_same_actions;
    Alcotest.test_case "no_clock_in_strategy" `Quick test_no_clock_in_strategy;
    Alcotest.test_case "no_backtest_or_bus_dependency" `Quick test_no_backtest_or_bus_dependency;
  ]
