open Algostream_risk_management

let feed_stable detector value n =
  let last = ref Correlation_breakdown.Stable in
    for _ = 1 to n do
      last := Correlation_breakdown.Detector.update detector ~correlation:value
    done ;
    !last


let test_stable_when_steady () =
  let d = Correlation_breakdown.Detector.create () in
  let status = feed_stable d 0.8 200 in
    Alcotest.(check bool)
      "steady high corr → Stable" true
      (match status with Correlation_breakdown.Stable -> true | _ -> false)


let test_broken_down_on_drop () =
  let d =
    Correlation_breakdown.Detector.create ~baseline_period:60 ~current_period:5
      ~breakdown_threshold:0.3 () in
  let _ = feed_stable d 0.9 200 in
  (* Now drop sharply *)
  let last_status = ref Correlation_breakdown.Stable in
    for _ = 1 to 20 do
      last_status := Correlation_breakdown.Detector.update d ~correlation:0.3
    done ;
    Alcotest.(check bool)
      (Printf.sprintf "after drop: status = %s"
         (Correlation_breakdown.status_to_string !last_status))
      true
      (match !last_status with
      | Correlation_breakdown.Broken_down _ | Correlation_breakdown.Weakening _ -> true
      | _ -> false)


let test_sign_flipped () =
  let d =
    Correlation_breakdown.Detector.create ~baseline_period:60 ~current_period:5
      ~breakdown_threshold:0.3 () in
  let _ = feed_stable d 0.9 200 in
  let last_status = ref Correlation_breakdown.Stable in
    for _ = 1 to 30 do
      last_status := Correlation_breakdown.Detector.update d ~correlation:(-0.7)
    done ;
    Alcotest.(check bool)
      (Printf.sprintf "after sign flip: status = %s"
         (Correlation_breakdown.status_to_string !last_status))
      true
      (match !last_status with
      | Correlation_breakdown.Sign_flipped _ | Correlation_breakdown.Broken_down _ -> true
      | _ -> false)


let suite =
  [
    Alcotest.test_case "stable_when_steady" `Quick test_stable_when_steady;
    Alcotest.test_case "broken_down_on_drop" `Quick test_broken_down_on_drop;
    Alcotest.test_case "sign_flipped" `Quick test_sign_flipped;
  ]
