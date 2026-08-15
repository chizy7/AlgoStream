open Algostream_advanced_models

let test_recovers_persistence () =
  (* Variance targeting recovers α+β (persistence) most reliably; individual α / β can be imprecise
     on finite samples. *)
  let omega = 0.05 in
  let alpha = 0.10 in
  let beta = 0.85 in
  let returns = Helpers.garch_series ~n:3000 ~omega ~alpha ~beta ~seed:73 in
    match Garch11.fit ~returns () with
    | Error _ -> Alcotest.fail "GARCH fit failed"
    | Ok r ->
      let persistence = r.params.alpha +. r.params.beta in
        Alcotest.(check bool)
          (Printf.sprintf "α+β=%g near 0.95 (α=%g β=%g)" persistence r.params.alpha r.params.beta)
          true
          (abs_float (persistence -. (alpha +. beta)) < 0.10)


let test_forecast_mean_reverts_to_long_run () =
  let returns = Helpers.garch_series ~n:1000 ~omega:0.05 ~alpha:0.10 ~beta:0.85 ~seed:74 in
    match Garch11.fit ~returns () with
    | Error _ -> Alcotest.fail "fit failed"
    | Ok r ->
      let online = Garch11.of_fit r ~last_return:returns.(999) ~last_variance:r.long_run_variance in
      let fc = Garch11.forecast online ~horizon:200 in
      let far = fc.(199) in
        Alcotest.(check bool)
          (Printf.sprintf "horizon=200 forecast %g near long_run %g" far r.long_run_variance)
          true
          (abs_float (far -. r.long_run_variance) < 0.05 *. r.long_run_variance)


let test_fit_insufficient_data () =
  let small = Array.make 5 0.1 in
    match Garch11.fit ~returns:small () with
    | Error (`Insufficient_data (5, 32)) -> ()
    | _ -> Alcotest.fail "expected Insufficient_data"


let test_online_update () =
  let returns = Helpers.garch_series ~n:500 ~omega:0.05 ~alpha:0.10 ~beta:0.85 ~seed:75 in
    match Garch11.fit ~returns () with
    | Error _ -> Alcotest.fail "fit failed"
    | Ok r ->
      let online = Garch11.of_fit r ~last_return:0.0 ~last_variance:r.long_run_variance in
      let next = Garch11.update online ~r:0.2 in
        Alcotest.(check bool) "update returns positive variance" true (next > 0.0) ;
        Alcotest.(check bool)
          "current_variance matches" true
          (abs_float (Garch11.current_variance online -. next) < 1e-12)


let suite =
  [
    Alcotest.test_case "recovers_persistence" `Quick test_recovers_persistence;
    Alcotest.test_case "forecast_mean_reverts_to_long_run" `Quick
      test_forecast_mean_reverts_to_long_run;
    Alcotest.test_case "fit_insufficient_data" `Quick test_fit_insufficient_data;
    Alcotest.test_case "online_update" `Quick test_online_update;
  ]
