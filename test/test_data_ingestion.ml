open Alcotest
open Data_ingestion

let test_fetch_data () =
  check string "same string" "Data fetched" (fetch_data ())

let () =
  run "Data Ingestion Tests" [
    "fetch_data", [test_case "Test fetch_data" `Quick test_fetch_data];
  ]