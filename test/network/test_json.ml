module Json = Algostream_infrastructure_network.Json

(* The guard this module exists for. Yojson emits bare NaN/Infinity, which is not JSON and which
   JSON.parse rejects outright — one degenerate Sharpe ratio would make the whole dashboard payload
   unreadable. *)
let test_non_finite_floats_become_null () =
  Alcotest.(check string) "nan" "null" (Json.to_string (Json.float Float.nan)) ;
  Alcotest.(check string) "inf" "null" (Json.to_string (Json.float Float.infinity)) ;
  Alcotest.(check string) "-inf" "null" (Json.to_string (Json.float Float.neg_infinity)) ;
  Alcotest.(check string) "finite survives" "1.5" (Json.to_string (Json.float 1.5)) ;
  (* And through the assoc path, which is how every metrics blob is built. *)
  let s = Json.to_string (Json.of_assoc [ ("sharpe", Float.nan); ("nav", 100.0) ]) in
    Alcotest.(check bool)
      (Printf.sprintf "assoc guards too: %s" s)
      true
      (String.equal s {|{"sharpe":null,"nav":100.0}|})


let is_parseable s = match Yojson.Safe.from_string s with _ -> true | exception _ -> false

let test_output_parses () =
  let j =
    Json.obj
      [
        ("a", Json.float Float.nan);
        ("b", Json.int64 9_223_372_036_854_775_807L);
        ("c", Json.list Json.string [ "x"; "y" ]);
        ("d", Json.opt Json.float None);
        ("e", Json.bool true);
      ] in
  let s = Json.to_string j in
    Alcotest.(check bool) (Printf.sprintf "round-trips: %s" s) true (is_parseable s)


(* int64 goes out as a JSON number, not a string — nanosecond timestamps exceed 2^53 and would lose
   precision if the browser parsed them as doubles, but they must still be numbers for charting. *)
let test_int64_is_a_number () =
  let s = Json.to_string (Json.int64 1_785_889_842_614_000_000L) in
    Alcotest.(check string) "no quotes" "1785889842614000000" s


let test_series_shape () =
  let s = Json.to_string (Json.of_series [| (1L, 10.0); (2L, 20.0) |]) in
    Alcotest.(check string) "pairs of [ts, value]" "[[1,10.0],[2,20.0]]" s


let suite =
  [
    Alcotest.test_case "non_finite_floats_become_null" `Quick test_non_finite_floats_become_null;
    Alcotest.test_case "output_parses" `Quick test_output_parses;
    Alcotest.test_case "int64_is_a_number" `Quick test_int64_is_a_number;
    Alcotest.test_case "series_shape" `Quick test_series_shape;
  ]
