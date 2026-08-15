(* Argument-vector normalisation.

   The k8s manifests were written with --flag=value, every binary's parser matched exact flag
   strings, and the mismatch produced "unknown argument --http-host=0.0.0.0" at container start.
   kubectl --dry-run and kubeconform both passed the manifests, because neither validates what a
   container's arguments mean. Only applying them to a real cluster surfaced it. *)

module Cli = Algostream_common_utils.Cli

let check name input expected =
  let got = Array.to_list (Cli.expand_equals (Array.of_list input)) in
    Alcotest.(check (list string)) name expected got


let test_splits_flag_equals_value () =
  check "the case the manifests needed"
    [ "algostream"; "--http-host=0.0.0.0"; "--http-port=8080" ]
    [ "algostream"; "--http-host"; "0.0.0.0"; "--http-port"; "8080" ]


let test_space_form_is_untouched () =
  (* Every existing invocation must keep working; this is the one that would break users. *)
  check "space-separated passes through"
    [ "algostream"; "--http-host"; "0.0.0.0"; "--gc-tune" ]
    [ "algostream"; "--http-host"; "0.0.0.0"; "--gc-tune" ]


let test_only_the_first_equals_splits () =
  (* A path or query string in the value must survive. Splitting on every '=' would silently
     truncate --auth-keys to the text before the first one. *)
  check "value keeps its own equals signs" [ "--audit-dir=/var/lib/a=b/c" ]
    [ "--audit-dir"; "/var/lib/a=b/c" ]


let test_non_flag_tokens_are_not_split () =
  check "a positional argument containing = is left alone" [ "prog"; "KEY=VALUE"; "-x=1" ]
    [ "prog"; "KEY=VALUE"; "-x=1" ]


let test_degenerate_tokens_are_left_alone () =
  (* "--" is the conventional end-of-flags marker and must not become an empty flag; "--=v" has no
     flag name at all, so passing it through unchanged lets the parser report it as unknown rather
     than matching "" against some case. *)
  check "-- and --=v are passed through" [ "--"; "--=v"; "--a=b" ] [ "--"; "--=v"; "--a"; "b" ]


let test_flag_with_empty_value () =
  check "--flag= yields an empty value rather than dropping the flag" [ "--static=" ]
    [ "--static"; "" ]


let suite =
  [
    Alcotest.test_case "splits_flag_equals_value" `Quick test_splits_flag_equals_value;
    Alcotest.test_case "space_form_is_untouched" `Quick test_space_form_is_untouched;
    Alcotest.test_case "only_the_first_equals_splits" `Quick test_only_the_first_equals_splits;
    Alcotest.test_case "non_flag_tokens_are_not_split" `Quick test_non_flag_tokens_are_not_split;
    Alcotest.test_case "degenerate_tokens_are_left_alone" `Quick
      test_degenerate_tokens_are_left_alone;
    Alcotest.test_case "flag_with_empty_value" `Quick test_flag_with_empty_value;
  ]
