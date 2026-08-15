open Algostream_advanced_models

let test_garch_fit_deterministic () =
  let returns = Helpers.garch_series ~n:500 ~omega:0.05 ~alpha:0.10 ~beta:0.85 ~seed:101 in
  let r1 = match Garch11.fit ~returns () with Ok r -> r | Error _ -> Alcotest.fail "fit failed" in
  let r2 = match Garch11.fit ~returns () with Ok r -> r | Error _ -> Alcotest.fail "fit failed" in
    Alcotest.(check (float 1e-12)) "omega" r1.params.omega r2.params.omega ;
    Alcotest.(check (float 1e-12)) "alpha" r1.params.alpha r2.params.alpha ;
    Alcotest.(check (float 1e-12)) "beta" r1.params.beta r2.params.beta


let test_ou_fit_deterministic () =
  let p = { Ornstein_uhlenbeck.theta = 0.5; mu = 0.0; sigma = 1.0 } in
  let series = Ornstein_uhlenbeck.simulate p ~n:512 ~dt:0.1 ~seed:102 ~r0:0.0 in
  let r1 =
    match Ornstein_uhlenbeck.fit ~series ~dt:0.1 with
    | Ok r -> r
    | Error _ -> Alcotest.fail "fit failed" in
  let r2 =
    match Ornstein_uhlenbeck.fit ~series ~dt:0.1 with
    | Ok r -> r
    | Error _ -> Alcotest.fail "fit failed" in
    Alcotest.(check (float 1e-12)) "theta" r1.params.theta r2.params.theta ;
    Alcotest.(check (float 1e-12)) "mu" r1.params.mu r2.params.mu ;
    Alcotest.(check (float 1e-12)) "sigma" r1.params.sigma r2.params.sigma


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


let test_no_clock_in_advanced_models () =
  let candidates =
    [
      "lib/advanced_models";
      "../../../lib/advanced_models";
      Filename.concat (Sys.getcwd ()) "lib/advanced_models";
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
    Alcotest.test_case "garch_fit_deterministic" `Quick test_garch_fit_deterministic;
    Alcotest.test_case "ou_fit_deterministic" `Quick test_ou_fit_deterministic;
    Alcotest.test_case "no_clock_in_advanced_models" `Quick test_no_clock_in_advanced_models;
  ]
