module Server = Algostream_infrastructure_network.Server
module Json = Algostream_infrastructure_network.Json

let route meth path : Server.route =
  {
    Server.meth;
    path;
    scope = Algostream_infrastructure_auth.Scope.Read;
    handler = (fun _ -> (Json.obj [ ("ok", Json.bool true) ], 200));
  }


let routes =
  [
    route `GET "/api/health";
    route `GET "/api/strategies";
    route `GET "/api/strategies/:id";
    route `POST "/api/strategies/:id/pause";
    route `PUT "/api/strategies/:id/allocation";
  ]


let test_exact_match () =
  match Server.match_route routes ~meth:`GET ~path:"/api/health" with
  | Some (r, params) ->
    Alcotest.(check string) "matched path" "/api/health" r.Server.path ;
    Alcotest.(check int) "no params" 0 (List.length params)
  | None -> Alcotest.fail "expected a match"


let test_param_extraction () =
  match Server.match_route routes ~meth:`POST ~path:"/api/strategies/pairs-1/pause" with
  | Some (r, params) ->
    Alcotest.(check string) "matched" "/api/strategies/:id/pause" r.Server.path ;
    Alcotest.(check (option string)) "id captured" (Some "pairs-1") (List.assoc_opt "id" params)
  | None -> Alcotest.fail "expected a match"


(* A longer path must not match a shorter pattern, or /api/strategies/:id would swallow
   /api/strategies/:id/pause. *)
let test_length_is_significant () =
  Alcotest.(check bool)
    "extra segment does not match" true
    (Option.is_none (Server.match_route routes ~meth:`GET ~path:"/api/strategies/x/extra")) ;
  Alcotest.(check bool)
    "missing segment does not match" true
    (Option.is_none (Server.match_route routes ~meth:`POST ~path:"/api/strategies/pause"))


let test_method_is_significant () =
  Alcotest.(check bool)
    "GET on a POST route misses" true
    (Option.is_none (Server.match_route routes ~meth:`GET ~path:"/api/strategies/x/pause")) ;
  Alcotest.(check bool)
    "POST on the right route hits" true
    (Option.is_some (Server.match_route routes ~meth:`POST ~path:"/api/strategies/x/pause"))


let test_trailing_slash_is_ignored () =
  Alcotest.(check bool)
    "trailing slash still matches" true
    (Option.is_some (Server.match_route routes ~meth:`GET ~path:"/api/health/"))


let test_unknown_path () =
  Alcotest.(check bool)
    "no route" true
    (Option.is_none (Server.match_route routes ~meth:`GET ~path:"/api/nope"))


let test_query_parsing () =
  let q = Server.parse_query "symbol=BTCUSDT&interval=60&empty=&flag" in
    Alcotest.(check (option string)) "symbol" (Some "BTCUSDT") (List.assoc_opt "symbol" q) ;
    Alcotest.(check (option string)) "interval" (Some "60") (List.assoc_opt "interval" q) ;
    Alcotest.(check (option string)) "empty value" (Some "") (List.assoc_opt "empty" q) ;
    Alcotest.(check (option string)) "valueless key" (Some "") (List.assoc_opt "flag" q) ;
    Alcotest.(check int) "empty string yields nothing" 0 (List.length (Server.parse_query ""))


let test_percent_decoding () =
  let q = Server.parse_query "pair=BTC%2FUSDT&note=a+b%20c" in
    Alcotest.(check (option string)) "slash decoded" (Some "BTC/USDT") (List.assoc_opt "pair" q) ;
    Alcotest.(check (option string))
      "plus and %20 both become space" (Some "a b c") (List.assoc_opt "note" q)


(* Regression: /dashboard/ used to 404 because the static handler rejected directories and only fell
   back to index.html at the root. The dashboard was therefore unreachable at the URL the daemon
   advertised. *)
let test_static_directory_serves_index () =
  let root = Filename.get_temp_dir_name () in
  let dir = Filename.concat root "algostream_static_test" in
  let sub = Filename.concat dir "dashboard" in
    (try Unix.mkdir dir 0o755 with _ -> ()) ;
    (try Unix.mkdir sub 0o755 with _ -> ()) ;
    let write p body =
      let oc = open_out p in
        output_string oc body ;
        close_out oc in
      write (Filename.concat dir "index.html") "root" ;
      write (Filename.concat sub "index.html") "dash" ;
      let read_via path =
        match Server.resolve_static ~root:dir ~path with
        | None -> None
        | Some f ->
          if Sys.file_exists f && not (Sys.is_directory f) then (
            let ic = open_in f in
            let n = in_channel_length ic in
            let s = really_input_string ic n in
              close_in ic ;
              Some s)
          else None in
        Alcotest.(check (option string)) "root serves its index" (Some "root") (read_via "/") ;
        Alcotest.(check (option string))
          "directory serves its index" (Some "dash") (read_via "/dashboard/") ;
        Alcotest.(check (option string))
          "explicit index still works" (Some "dash")
          (read_via "/dashboard/index.html") ;
        (* Traversal stays refused. *)
        Alcotest.(check bool)
          "parent traversal refused" true
          (Option.is_none (Server.resolve_static ~root:dir ~path:"/../etc/passwd"))


let suite =
  [
    Alcotest.test_case "exact_match" `Quick test_exact_match;
    Alcotest.test_case "param_extraction" `Quick test_param_extraction;
    Alcotest.test_case "length_is_significant" `Quick test_length_is_significant;
    Alcotest.test_case "method_is_significant" `Quick test_method_is_significant;
    Alcotest.test_case "trailing_slash_is_ignored" `Quick test_trailing_slash_is_ignored;
    Alcotest.test_case "unknown_path" `Quick test_unknown_path;
    Alcotest.test_case "query_parsing" `Quick test_query_parsing;
    Alcotest.test_case "percent_decoding" `Quick test_percent_decoding;
    Alcotest.test_case "static_directory_serves_index" `Quick test_static_directory_serves_index;
  ]
