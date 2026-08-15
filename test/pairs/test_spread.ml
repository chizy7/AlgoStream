open Algostream_pairs

let test_spread_mean_near_zero () =
  let sp = Spread.create ~window:128 ~recompute_every:16 in
  let rng = Random.State.make [| 7 |] in
  let beta = 1.5 in
    for i = 0 to 199 do
      let x = float_of_int i in
      let y = (beta *. x) +. Helpers.normal_sample rng in
        Spread.update sp ~y ~x ~beta ~intercept:0.0 ~ts_ns:(Int64.of_int (i * 1_000_000))
    done ;
    Alcotest.(check (float 0.5)) "spread mean near 0" 0.0 (Spread.mean sp) ;
    Alcotest.(check bool) "spread std > 0.5" true (Spread.std sp > 0.5)


let test_z_zero_when_std_zero () =
  let sp = Spread.create ~window:32 ~recompute_every:8 in
    for i = 0 to 31 do
      Spread.update sp ~y:0.0 ~x:0.0 ~beta:1.0 ~intercept:0.0 ~ts_ns:(Int64.of_int (i * 1_000_000))
    done ;
    Alcotest.(check (float 1e-9)) "z = 0 on flat spread" 0.0 (Spread.z sp)


let test_n_increments () =
  let sp = Spread.create ~window:32 ~recompute_every:8 in
    for i = 0 to 9 do
      Spread.update sp ~y:1.0 ~x:0.0 ~beta:1.0 ~intercept:0.0 ~ts_ns:(Int64.of_int (i * 1_000_000))
    done ;
    Alcotest.(check int) "n=10" 10 (Spread.n sp)


let suite =
  [
    Alcotest.test_case "spread_mean_near_zero" `Quick test_spread_mean_near_zero;
    Alcotest.test_case "z_zero_when_std_zero" `Quick test_z_zero_when_std_zero;
    Alcotest.test_case "n_increments" `Quick test_n_increments;
  ]
