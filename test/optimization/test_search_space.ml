module SS = Algostream_optimization.Search_space
module Rng = Algostream_rng.Rng

let space2 =
  [
    { SS.name = "a"; spec = SS.Grid [| 1.0; 2.0; 3.0 |] };
    { SS.name = "b"; spec = SS.Int_range { lo = 0; hi = 10; step = 5 } };
  ]


let test_cardinality () =
  (* 3 grid values x {0,5,10} = 9 *)
  Alcotest.(check (option int)) "3 x 3 = 9" (Some 9) (SS.cardinality space2) ;
  let continuous = [ { SS.name = "c"; spec = SS.Uniform { lo = 0.0; hi = 1.0 } } ] in
    Alcotest.(check (option int)) "continuous has no cardinality" None (SS.cardinality continuous)


let test_grid_points_enumerates_everything () =
  match SS.grid_points space2 ~max_points:100 with
  | Error _ -> Alcotest.fail "unexpectedly refused"
  | Ok pts ->
    Alcotest.(check int) "nine points" 9 (Array.length pts) ;
    let seen = Hashtbl.create 9 in
      Array.iter
        (fun p ->
          let key = Printf.sprintf "%g/%g" (List.assoc "a" p) (List.assoc "b" p) in
            Hashtbl.replace seen key ())
        pts ;
      Alcotest.(check int) "all distinct" 9 (Hashtbl.length seen)


let test_of_bounds () =
  let s = SS.of_bounds [ ("x", 0.0, 1.0) ] ~points_per_dim:5 () in
    Alcotest.(check (option int)) "five points on one axis" (Some 5) (SS.cardinality s)


let test_log_uniform_stays_in_range () =
  let s = [ { SS.name = "L"; spec = SS.Log_uniform { lo = 0.001; hi = 1000.0 } } ] in
  let rng = Rng.create ~seed:2 in
    for _ = 1 to 10_000 do
      let v = List.assoc "L" (SS.sample s rng) in
        if v < 0.001 || v > 1000.0 then Alcotest.failf "log-uniform sample %g out of range" v
    done ;
    Alcotest.(check bool) "all samples in range" true true


let test_clamp_snaps_to_grid () =
  let p = SS.clamp space2 [ ("a", 2.4); ("b", 7.0) ] in
    Alcotest.(check (float 1e-9)) "2.4 snaps to the nearest grid value 2" 2.0 (List.assoc "a" p) ;
    Alcotest.(check (float 1e-9)) "7 snaps to 5" 5.0 (List.assoc "b" p)


let test_neighbours_are_adjacent () =
  let n = SS.neighbours space2 [ ("a", 2.0); ("b", 5.0) ] in
    Alcotest.(check bool) "some neighbours exist" true (Array.length n > 0) ;
    Array.iter
      (fun p ->
        let a = List.assoc "a" p and b = List.assoc "b" p in
          Alcotest.(check bool)
            (Printf.sprintf "neighbour (%g,%g) differs in exactly one axis by one step" a b)
            true
            ((a <> 2.0 && b = 5.0) || (a = 2.0 && b <> 5.0)))
      n


let test_stratified_covers_every_stratum () =
  (* The defining LHS property: with n samples over a continuous axis, every one of the n equal
     strata receives exactly one point. This is what a mis-transcribed Sobol table would silently
     fail, and what makes correctness here checkable rather than assumed. *)
  let s = [ { SS.name = "u"; spec = SS.Uniform { lo = 0.0; hi = 1.0 } } ] in
  let n = 64 in
  let pts = SS.stratified_points s (Rng.create ~seed:5) ~n in
    Alcotest.(check int) "n points" n (Array.length pts) ;
    let hit = Array.make n 0 in
      Array.iter
        (fun p ->
          let v = List.assoc "u" p in
          let stratum = min (n - 1) (int_of_float (v *. float_of_int n)) in
            hit.(stratum) <- hit.(stratum) + 1)
        pts ;
      Array.iteri
        (fun i c ->
          Alcotest.(check int) (Printf.sprintf "stratum %d holds exactly one point" i) 1 c)
        hit


let test_stratified_works_at_any_dimension () =
  let big =
    List.init 12 (fun i ->
      { SS.name = Printf.sprintf "p%d" i; spec = SS.Uniform { lo = 0.0; hi = 1.0 } }) in
    Alcotest.(check bool) "no dimension limit" true (SS.stratified_supported big) ;
    let pts = SS.stratified_points big (Rng.create ~seed:1) ~n:16 in
      Alcotest.(check int) "returns the requested count at 12 dimensions" 16 (Array.length pts)


let suite =
  [
    Alcotest.test_case "cardinality" `Quick test_cardinality;
    Alcotest.test_case "grid_points_enumerates_everything" `Quick
      test_grid_points_enumerates_everything;
    Alcotest.test_case "of_bounds" `Quick test_of_bounds;
    Alcotest.test_case "log_uniform_stays_in_range" `Quick test_log_uniform_stays_in_range;
    Alcotest.test_case "clamp_snaps_to_grid" `Quick test_clamp_snaps_to_grid;
    Alcotest.test_case "neighbours_are_adjacent" `Quick test_neighbours_are_adjacent;
    Alcotest.test_case "stratified_covers_every_stratum" `Quick test_stratified_covers_every_stratum;
    Alcotest.test_case "stratified_works_at_any_dimension" `Quick
      test_stratified_works_at_any_dimension;
  ]
