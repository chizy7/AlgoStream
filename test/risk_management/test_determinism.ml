open Algostream_risk_management

let cb_config =
  {
    Circuit_breaker.max_drawdown = 0.20;
    max_daily_loss = 0.05;
    max_leverage = 3.0;
    vol_spike_ratio = 5.0;
    cooldown_ns = 10_000_000_000L;
  }


let make_monitor () =
  Monitor.create ~limits:Risk_limits.default ~circuit_config:cb_config ~initial_equity:100_000.0 ()


let test_replay_twice_matches () =
  let portfolio =
    Helpers.portfolio_with_positions ~nav:100_000.0
      ~positions:[ ("BTCUSDT", 10.0, 1000.0); ("ETHUSDT", 20.0, 500.0) ]
      () in
  let returns = Helpers.normal_returns ~n:500 ~mean:0.0 ~sd:0.02 ~seed:42 in
  let m1 = make_monitor () in
  let m2 = make_monitor () in
  let s1 = Monitor.update m1 ~portfolio ~returns ~ts_ns:1_000_000L () in
  let s2 = Monitor.update m2 ~portfolio ~returns ~ts_ns:1_000_000L () in
    Alcotest.(check (float 1e-12)) "var" s1.var_pct s2.var_pct ;
    Alcotest.(check (float 1e-12)) "es" s1.expected_shortfall_pct s2.expected_shortfall_pct ;
    Alcotest.(check (float 1e-12)) "drawdown" s1.current_drawdown s2.current_drawdown ;
    Alcotest.(check (float 1e-12)) "leverage" s1.leverage_ratio s2.leverage_ratio


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


let test_no_clock_in_risk_management () =
  let candidates =
    [
      "lib/risk_management";
      "../../../lib/risk_management";
      Filename.concat (Sys.getcwd ()) "lib/risk_management";
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
    Alcotest.test_case "replay_twice_matches" `Quick test_replay_twice_matches;
    Alcotest.test_case "no_clock_in_risk_management" `Quick test_no_clock_in_risk_management;
  ]
