(* The determinism contract that makes every Monte Carlo number in this library trustworthy: a
   batch's result must not depend on how many Domains ran it. *)

module MC = Algostream_montecarlo
module Rng = Algostream_rng.Rng

let domain_counts = [ 1; 2; 4; 8 ]

let test_results_are_index_ordered () =
  (* Deliberately unequal work: later indices are much slower, so completion order differs sharply
     from index order. If results were appended on completion this would fail. *)
  let f i =
    let acc = ref 0 in
      for j = 0 to i mod 7 * 20_000 do
        acc := (!acc + j) land 0xFFFF
      done ;
      ignore !acc ;
      i * i in
  let expected = Array.init 64 (fun i -> i * i) in
    List.iter
      (fun nd ->
        let got = MC.Pool.map ~n_domains:nd ~n:64 ~f in
          Array.iteri
            (fun i e ->
              if got.(i) <> e then
                Alcotest.failf "n_domains=%d: slot %d holds %d, expected %d" nd i got.(i) e)
            expected)
      domain_counts ;
    Alcotest.(check bool) "index order preserved at 1, 2, 4 and 8 Domains" true true


(* THE test. Substream-seeded work must be bit-identical across core counts. *)
let test_rng_work_is_core_count_independent () =
  let f i =
    let r = Rng.substream ~root_seed:9001L ~index:i in
    let acc = ref 0.0 in
      for _ = 1 to 50 do
        acc := !acc +. Rng.uniform r
      done ;
      !acc in
  let baseline = MC.Pool.map ~n_domains:1 ~n:256 ~f in
    List.iter
      (fun nd ->
        let got = MC.Pool.map ~n_domains:nd ~n:256 ~f in
          Array.iteri
            (fun i b ->
              if b <> got.(i) then
                Alcotest.failf "n_domains=%d: run %d gave %.17g, single-domain gave %.17g" nd i
                  got.(i) b)
            baseline)
      domain_counts ;
    Alcotest.(check bool) "bit-identical at every core count" true true


let test_empty_and_single () =
  Alcotest.(check int)
    "n=0 returns empty" 0
    (Array.length (MC.Pool.map ~n_domains:4 ~n:0 ~f:(fun i -> i))) ;
  Alcotest.(check (array int)) "n=1" [| 42 |] (MC.Pool.map ~n_domains:8 ~n:1 ~f:(fun _ -> 42))


(* A failure must surface the same way regardless of scheduling: the lowest failing index. *)
let test_exception_is_deterministic () =
  let f i = if i = 7 || i = 19 then failwith (Printf.sprintf "boom-%d" i) else i in
    List.iter
      (fun nd ->
        match MC.Pool.map ~n_domains:nd ~n:32 ~f with
        | exception Failure msg ->
          Alcotest.(check string)
            (Printf.sprintf "n_domains=%d raises the lowest failing index" nd)
            "boom-7" msg
        | _ -> Alcotest.failf "n_domains=%d: expected an exception" nd)
      domain_counts


let test_map_result_isolates_failures () =
  let f i = if i mod 5 = 0 then failwith "nope" else i in
  let rs = MC.Pool.map_result ~n_domains:4 ~n:20 ~f in
    Alcotest.(check int) "20 slots returned" 20 (Array.length rs) ;
    Array.iteri
      (fun i r ->
        match r with
        | Ok v -> Alcotest.(check int) "value matches index" i v
        | Error _ -> Alcotest.(check bool) "only multiples of 5 fail" true (i mod 5 = 0))
      rs


let test_recommended_domains_is_sane () =
  let n = MC.Pool.recommended_domains () in
    Alcotest.(check bool) (Printf.sprintf "recommended_domains = %d >= 1" n) true (n >= 1)


let suite =
  [
    Alcotest.test_case "results_are_index_ordered" `Quick test_results_are_index_ordered;
    Alcotest.test_case "rng_work_is_core_count_independent" `Quick
      test_rng_work_is_core_count_independent;
    Alcotest.test_case "empty_and_single" `Quick test_empty_and_single;
    Alcotest.test_case "exception_is_deterministic" `Quick test_exception_is_deterministic;
    Alcotest.test_case "map_result_isolates_failures" `Quick test_map_result_isolates_failures;
    Alcotest.test_case "recommended_domains_is_sane" `Quick test_recommended_domains_is_sane;
  ]
