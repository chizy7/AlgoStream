module D = Algostream_normalization.Data_break

let mk_tick ~symbol ~ts ~price ~size = { D.symbol; ts_ns = ts; price; size }

let test_pass_before_effective () =
  let entry = { D.effective_at_ns = 1000L; break_ = Halt { until_ns = 2000L }; source = "t" } in
    match D.apply [ entry ] (mk_tick ~symbol:"X" ~ts:500L ~price:100.0 ~size:1.0) with
    | D.Pass -> ()
    | _ -> Alcotest.fail "expected Pass before effective"


let test_halt_drops () =
  let entry = { D.effective_at_ns = 1000L; break_ = Halt { until_ns = 2000L }; source = "t" } in
    match D.apply [ entry ] (mk_tick ~symbol:"X" ~ts:1500L ~price:100.0 ~size:1.0) with
    | D.Drop -> ()
    | _ -> Alcotest.fail "expected Drop during halt"


let test_split_rewrites () =
  let entry = { D.effective_at_ns = 1000L; break_ = Split { ratio = 2.0 }; source = "t" } in
    match D.apply [ entry ] (mk_tick ~symbol:"X" ~ts:2000L ~price:100.0 ~size:1.0) with
    | D.Rewrite t ->
      Alcotest.(check (float 1e-9)) "halved price" 50.0 t.price ;
      Alcotest.(check (float 1e-9)) "doubled size" 2.0 t.size
    | _ -> Alcotest.fail "expected Rewrite from split"


let test_symbol_change () =
  let entry =
    {
      D.effective_at_ns = 1000L;
      break_ = Symbol_change { from_ = "OLD"; to_ = "NEW" };
      source = "t";
    } in
    match D.apply [ entry ] (mk_tick ~symbol:"OLD" ~ts:2000L ~price:100.0 ~size:1.0) with
    | D.Rewrite t -> Alcotest.(check string) "symbol renamed" "NEW" t.symbol
    | _ -> Alcotest.fail "expected Rewrite from symbol_change"


let test_fork_emits_synthetic () =
  let entry =
    {
      D.effective_at_ns = 1000L;
      break_ = Fork { parent = "OLD"; children = [ ("A", 1.0); ("B", 0.5) ] };
      source = "t";
    } in
    match D.apply [ entry ] (mk_tick ~symbol:"OLD" ~ts:2000L ~price:100.0 ~size:10.0) with
    | D.Emit_synthetic ts ->
      Alcotest.(check int) "two synthetics" 2 (List.length ts) ;
      let a = List.nth ts 0 in
      let b = List.nth ts 1 in
        Alcotest.(check string) "A" "A" a.symbol ;
        Alcotest.(check (float 1e-9)) "A size" 10.0 a.size ;
        Alcotest.(check string) "B" "B" b.symbol ;
        Alcotest.(check (float 1e-9)) "B size" 5.0 b.size
    | _ -> Alcotest.fail "expected Emit_synthetic from fork"


let suite =
  [
    Alcotest.test_case "pass_before_effective" `Quick test_pass_before_effective;
    Alcotest.test_case "halt_drops" `Quick test_halt_drops;
    Alcotest.test_case "split_rewrites" `Quick test_split_rewrites;
    Alcotest.test_case "symbol_change" `Quick test_symbol_change;
    Alcotest.test_case "fork_emits_synthetic" `Quick test_fork_emits_synthetic;
  ]
