module O = Algostream_analytics.Outlier

let pipe filters =
  List.map
    (fun (name, runner) ->
      let _ = name in
        runner)
    filters


let test_sanity_first () =
  match O.Sanity.update O.sanity (-1.0) with
  | O.Reject _ -> ()
  | O.Pass -> Alcotest.fail "sanity should reject negative"


let test_z_score_warmup_passes_all () =
  let z = O.Z_score.create ~threshold:3.0 ~warmup:30 ~ewma_period:10 in
    for i = 1 to 30 do
      let v = float_of_int i +. 0.0 in
        match O.Z_score.update z v with
        | Pass -> ()
        | Reject _ -> Alcotest.failf "warmup tick %d rejected" i
    done


let test_z_score_rejects_spike () =
  let z = O.Z_score.create ~threshold:3.0 ~warmup:30 ~ewma_period:10 in
  let rng = Random.State.make [| 99 |] in
    for _ = 1 to 200 do
      let v = 100.0 +. Random.State.float rng 1.0 in
      let _ = O.Z_score.update z v in
        ()
    done ;
    match O.Z_score.update z 1000.0 with
    | Reject _ -> ()
    | Pass -> Alcotest.fail "extreme spike not rejected"


let test_pipeline_short_circuits () =
  let z = O.Z_score.create ~threshold:3.0 ~warmup:0 ~ewma_period:10 in
  let runners = [ O.wrap (module O.Sanity) O.sanity; O.wrap (module O.Z_score) z ] in
  let _ = pipe in
    match O.run runners (-5.0) with
    | Reject { severity; _ } -> Alcotest.(check int) "sanity (severity 3) wins" 3 severity
    | Pass -> Alcotest.fail "pipeline did not reject negative"


let suite =
  [
    Alcotest.test_case "sanity_first" `Quick test_sanity_first;
    Alcotest.test_case "z_score_warmup_passes_all" `Quick test_z_score_warmup_passes_all;
    Alcotest.test_case "z_score_rejects_spike" `Quick test_z_score_rejects_spike;
    Alcotest.test_case "pipeline_short_circuits" `Quick test_pipeline_short_circuits;
  ]
