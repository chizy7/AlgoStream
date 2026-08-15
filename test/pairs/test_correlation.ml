open Algostream_pairs

let test_high_corr () =
  let c = Correlation.create ~window:64 ~recompute_every:8 in
  let rng = Random.State.make [| 31 |] in
    for _ = 0 to 199 do
      let x = Helpers.normal_sample rng in
      let y = x +. (0.01 *. Helpers.normal_sample rng) in
      let _ = Correlation.update c ~y ~x in
        ()
    done ;
    Alcotest.(check bool)
      (Printf.sprintf "corr=%g > 0.99" (Correlation.value c))
      true
      (Correlation.value c > 0.99)


let test_negative_corr () =
  let c = Correlation.create ~window:64 ~recompute_every:8 in
  let rng = Random.State.make [| 32 |] in
    for _ = 0 to 199 do
      let x = Helpers.normal_sample rng in
      let y = -.x +. (0.01 *. Helpers.normal_sample rng) in
      let _ = Correlation.update c ~y ~x in
        ()
    done ;
    Alcotest.(check bool)
      (Printf.sprintf "corr=%g < -0.99" (Correlation.value c))
      true
      (Correlation.value c < -0.99)


let test_zero_corr () =
  let c = Correlation.create ~window:128 ~recompute_every:16 in
  let rng_x = Random.State.make [| 33 |] in
  let rng_y = Random.State.make [| 34 |] in
    for _ = 0 to 999 do
      let _ =
        Correlation.update c ~y:(Helpers.normal_sample rng_y) ~x:(Helpers.normal_sample rng_x) in
        ()
    done ;
    Alcotest.(check bool)
      (Printf.sprintf "|corr|=%g small" (Correlation.value c))
      true
      (abs_float (Correlation.value c) < 0.2)


let suite =
  [
    Alcotest.test_case "high_corr" `Quick test_high_corr;
    Alcotest.test_case "negative_corr" `Quick test_negative_corr;
    Alcotest.test_case "zero_corr" `Quick test_zero_corr;
  ]
