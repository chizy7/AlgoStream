module CF = Algostream_normalization.Cross_feed
module Sym = Algostream_normalization.Symbol

let canonical = { Sym.base = "BTC"; quote = "USD"; asset_class = Crypto }

let test_basis_zero_when_aligned () =
  let cf = CF.create ~canonical ~feed_a:"a" ~feed_b:"b" () in
    for i = 1 to 200 do
      CF.update cf ~ts_ns:(Int64.of_int i) ~price_a:100.0 ~price_b:100.0
    done ;
    let s = CF.stats cf in
      Alcotest.(check (float 1e-9)) "mean basis ≈ 0" 0.0 s.mean_basis


let test_basis_signal_on_diverge () =
  let cf = CF.create ~canonical ~feed_a:"a" ~feed_b:"b" () in
    for i = 1 to 200 do
      CF.update cf ~ts_ns:(Int64.of_int i) ~price_a:100.0 ~price_b:100.5
    done ;
    let s = CF.stats cf in
      (* basis = (100 - 100.5) / 100.25 ≈ -0.005 *)
      Alcotest.(check bool) "negative mean basis" true (s.mean_basis < 0.0)


let test_z_score_on_anomaly () =
  let cf = CF.create ~canonical ~feed_a:"a" ~feed_b:"b" () in
  (* normal regime: small basis with mild noise *)
  let rng = Random.State.make [| 1 |] in
    for i = 1 to 200 do
      let noise = Random.State.float rng 0.02 -. 0.01 in
        CF.update cf ~ts_ns:(Int64.of_int i) ~price_a:(100.0 +. noise) ~price_b:100.0
    done ;
    (* anomaly *)
    CF.update cf ~ts_ns:201L ~price_a:105.0 ~price_b:100.0 ;
    let s = CF.stats cf in
      Alcotest.(check bool) "|z| > 2 on anomaly" true (abs_float s.current_z > 2.0)


let suite =
  [
    Alcotest.test_case "basis_zero_when_aligned" `Quick test_basis_zero_when_aligned;
    Alcotest.test_case "basis_signal_on_diverge" `Quick test_basis_signal_on_diverge;
    Alcotest.test_case "z_score_on_anomaly" `Quick test_z_score_on_anomaly;
  ]
