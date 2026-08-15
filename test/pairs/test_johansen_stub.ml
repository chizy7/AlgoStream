open Algostream_pairs

let test_returns_unsupported () =
  match Cointegration.Johansen.test () with
  | Error `Not_supported_in_v1 -> ()
  | Ok _ -> Alcotest.fail "Johansen should not be supported in v1"


let suite = [ Alcotest.test_case "returns_unsupported" `Quick test_returns_unsupported ]
