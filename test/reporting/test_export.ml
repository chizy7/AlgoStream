module Export = Algostream_reporting.Export
open Export

(* The bug this module exists to fix: strategy_id and tag are free text, and the pre-existing writer
   emitted them with a bare %s. One comma shifted every later column by one. *)
let test_csv_escaping () =
  Alcotest.(check string) "plain passes through" "abc" (Export.csv_escape "abc") ;
  Alcotest.(check string) "comma is quoted" "\"a,b\"" (Export.csv_escape "a,b") ;
  Alcotest.(check string) "quote is doubled" "\"say \"\"hi\"\"\"" (Export.csv_escape "say \"hi\"") ;
  Alcotest.(check string) "newline is quoted" "\"a\nb\"" (Export.csv_escape "a\nb") ;
  Alcotest.(check string) "carriage return is quoted" "\"a\rb\"" (Export.csv_escape "a\rb")


let test_csv_row_integrity () =
  let csv =
    Export.to_csv ~headers:[ "id"; "tag"; "qty" ]
      ~rows:[ [ S "s1"; S "entry, leg 2"; F 1.5 ]; [ S "s2"; S "plain"; F 2.0 ] ] in
  let lines = String.split_on_char '\n' csv |> List.filter (fun l -> not (String.equal l "")) in
    Alcotest.(check int) "header + 2 rows" 3 (List.length lines) ;
    (* The comma-bearing field must still be one field: three columns, not four. *)
    let count_unquoted_commas line =
      let n = String.length line in
      let rec go i inq acc =
        if i >= n then acc
        else
          match line.[i] with
          | '"' -> go (i + 1) (not inq) acc
          | ',' when not inq -> go (i + 1) inq (acc + 1)
          | _ -> go (i + 1) inq acc in
        go 0 false 0 in
      List.iter
        (fun l ->
          Alcotest.(check int)
            (Printf.sprintf "row keeps 3 columns: %s" l)
            2 (count_unquoted_commas l))
        lines


(* nan in a spreadsheet column poisons the whole column's type inference; an empty cell does not. *)
let test_non_finite_renders_empty () =
  Alcotest.(check string) "nan" "" (Export.value_to_csv (F Float.nan)) ;
  Alcotest.(check string) "inf" "" (Export.value_to_csv (F Float.infinity)) ;
  Alcotest.(check string) "finite" "1.5" (Export.value_to_csv (F 1.5))


let test_json_is_parseable_with_non_finite () =
  let s = Export.to_json ~headers:[ "a"; "b" ] ~rows:[ [ F Float.nan; I 3 ] ] in
    Alcotest.(check bool)
      (Printf.sprintf "parses: %s" s) true
      (match Yojson.Safe.from_string s with _ -> true | exception _ -> false) ;
    match Yojson.Safe.from_string s with
    | `List [ `Assoc kvs ] ->
      Alcotest.(check bool) "nan became null" true (List.assoc "a" kvs = `Null) ;
      Alcotest.(check bool) "int survived" true (List.assoc "b" kvs = `Int 3)
    | _ -> Alcotest.fail "expected a one-element array of objects"


let test_short_row_pads () =
  let s = Export.to_json ~headers:[ "a"; "b"; "c" ] ~rows:[ [ I 1 ] ] in
    Alcotest.(check bool)
      (Printf.sprintf "still valid json: %s" s)
      true
      (match Yojson.Safe.from_string s with _ -> true | exception _ -> false)


let test_format_parsing () =
  Alcotest.(check bool) "csv" true (Export.format_of_string "CSV" = Ok Export.Csv) ;
  Alcotest.(check bool) "json" true (Export.format_of_string "json" = Ok Export.Json) ;
  (* xlsx is refused with a reason rather than silently producing CSV under a misleading name. *)
  (match Export.format_of_string "xlsx" with
  | Error msg ->
    Alcotest.(check bool)
      (Printf.sprintf "xlsx explains itself: %s" msg)
      true
      (String.length msg > 10)
  | Ok _ -> Alcotest.fail "xlsx must not be accepted") ;
  match Export.format_of_string "pdf" with
  | Error _ -> ()
  | Ok _ -> Alcotest.fail "unknown format must be rejected"


let suite =
  [
    Alcotest.test_case "csv_escaping" `Quick test_csv_escaping;
    Alcotest.test_case "csv_row_integrity" `Quick test_csv_row_integrity;
    Alcotest.test_case "non_finite_renders_empty" `Quick test_non_finite_renders_empty;
    Alcotest.test_case "json_parseable_with_non_finite" `Quick
      test_json_is_parseable_with_non_finite;
    Alcotest.test_case "short_row_pads" `Quick test_short_row_pads;
    Alcotest.test_case "format_parsing" `Quick test_format_parsing;
  ]
