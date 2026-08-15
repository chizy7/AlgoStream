open Algostream_pairs

let make_snap pid ~corr ~p ~hl ~beta_sd : Snapshot.t =
  {
    (Snapshot.empty ~pair:pid) with
    n_ticks = 200;
    corr;
    beta = 1.0;
    beta_stdev = beta_sd;
    adf_p_value = p;
    half_life_bars = hl;
    avg_volume = 100.0;
  }


let test_pair_id_lexical_order () =
  let s1 = Helpers.sym "AAA" "USD" in
  let s2 = Helpers.sym "ZZZ" "USD" in
  let a = Pair_id.of_symbols s1 s2 in
  let b = Pair_id.of_symbols s2 s1 in
    Alcotest.(check bool) "ordering canonical" true (Pair_id.equal a b) ;
    Alcotest.(check string)
      "y is AAA" "AAA/USD"
      (Algostream_normalization.Symbol.to_canonical (Pair_id.y a))


let test_enumerate_all_pairs () =
  let syms = [ Helpers.sym "A" "U"; Helpers.sym "B" "U"; Helpers.sym "C" "U" ] in
  let ps = Selection.enumerate_pairs (Selection.All_pairs_of syms) in
    Alcotest.(check int) "3 choose 2 = 3" 3 (List.length ps)


let test_filters () =
  let pid_good = Helpers.pair "GOOD" "POS" in
  let pid_low_corr = Helpers.pair "LCRR" "X" in
  let pid_high_p = Helpers.pair "HPV" "Y" in
  let pid_short_hl = Helpers.pair "SHL" "Z" in
  let pid_unstable_beta = Helpers.pair "UBT" "W" in
  let snaps =
    [
      make_snap pid_good ~corr:0.95 ~p:0.01 ~hl:5.0 ~beta_sd:0.05;
      make_snap pid_low_corr ~corr:0.2 ~p:0.01 ~hl:5.0 ~beta_sd:0.05;
      make_snap pid_high_p ~corr:0.95 ~p:0.5 ~hl:5.0 ~beta_sd:0.05;
      make_snap pid_short_hl ~corr:0.95 ~p:0.01 ~hl:0.1 ~beta_sd:0.05;
      make_snap pid_unstable_beta ~corr:0.95 ~p:0.01 ~hl:5.0 ~beta_sd:2.0;
    ] in
  let cs = Selection.candidates snaps Selection.default_criteria in
    Alcotest.(check int) "only good pair passes" 1 (List.length cs) ;
    let only = List.hd cs in
      Alcotest.(check bool) "is the good pair" true (Pair_id.equal only.pair pid_good)


let test_ranking () =
  let p1 = Helpers.pair "ONE" "X" in
  let p2 = Helpers.pair "TWO" "X" in
  let snaps =
    [
      make_snap p1 ~corr:0.7 ~p:0.04 ~hl:50.0 ~beta_sd:0.1;
      make_snap p2 ~corr:0.95 ~p:0.001 ~hl:2.0 ~beta_sd:0.05;
    ] in
  let cs = Selection.candidates snaps Selection.default_criteria in
    Alcotest.(check int) "both pass" 2 (List.length cs) ;
    Alcotest.(check bool) "p2 ranks first" true (Pair_id.equal (List.hd cs).pair p2)


let suite =
  [
    Alcotest.test_case "pair_id_lexical_order" `Quick test_pair_id_lexical_order;
    Alcotest.test_case "enumerate_all_pairs" `Quick test_enumerate_all_pairs;
    Alcotest.test_case "filters" `Quick test_filters;
    Alcotest.test_case "ranking" `Quick test_ranking;
  ]
