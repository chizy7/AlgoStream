module V = Algostream_analytics.Volatility

let test_realized_zero_on_constant () =
  let r = V.Realized.create ~window:64 ~recompute_every:8 in
    for _ = 1 to 200 do
      let _ = V.Realized.update r ~price:100.0 in
        ()
    done ;
    Alcotest.(check bool) "vol ~ 0 on constant prices" true (V.Realized.value r < 1e-6)


let test_realized_higher_on_volatile () =
  let r = V.Realized.create ~window:64 ~recompute_every:8 in
  let rng = Random.State.make [| 123 |] in
    for _ = 1 to 500 do
      let p = 100.0 *. exp (Random.State.float rng 0.05 -. 0.025) in
      let _ = V.Realized.update r ~price:p in
        ()
    done ;
    Alcotest.(check bool) "vol non-zero on noise" true (V.Realized.value r > 0.001)


let test_ewma_vol_warmup_then_ready () =
  let e = V.Ewma.create ~period:30 in
    for _ = 1 to 5 do
      let _ = V.Ewma.update e ~price:100.0 in
        ()
    done ;
    Alcotest.(check bool) "not ready early" false (V.Ewma.ready e) ;
    for _ = 1 to 500 do
      let _ = V.Ewma.update e ~price:100.0 in
        ()
    done ;
    Alcotest.(check bool) "ready" true (V.Ewma.ready e)


let suite =
  [
    Alcotest.test_case "realized_zero_on_constant" `Quick test_realized_zero_on_constant;
    Alcotest.test_case "realized_higher_on_volatile" `Quick test_realized_higher_on_volatile;
    Alcotest.test_case "ewma_vol_warmup_then_ready" `Quick test_ewma_vol_warmup_then_ready;
  ]
