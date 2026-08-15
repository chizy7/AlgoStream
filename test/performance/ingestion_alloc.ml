(** Per-event allocation benchmark.

    Measures GC bytes allocated per parsed-and-published Binance bookTicker / Coinbase ticker
    payload. Reports words/event (one OCaml word = 8 bytes on 64-bit). The aspirational target is ≤
    ~16 words/event in steady state; the bench fails if it climbs above [alloc_words_threshold].

    Output is the github-action-benchmark customSmallerIsBetter schema. *)

module EB = Algostream_infrastructure_event_bus
module Event_bus = EB.Event_bus
module Event_types = EB.Event_types
module SI = Algostream_data_ingestion.Symbol_intern
module Binance = Algostream_data_ingestion_binance
module Coinbase = Algostream_data_ingestion_coinbase

let iters = 200_000

(* The v1 parser uses [Yojson.Safe.from_string] which materializes a full AST per frame: an [Assoc]
   list of (key, value) tuples plus boxed [`String]/[`Int] wrappers. For a 6-9-field frame this
   comes out at ~200-300 words. The planned follow-up is a hand-rolled hot-path parser; with that
   the budget should drop to ~16 words/event (1 envelope, 1 payload variant, trade_id string, plus
   interned symbol).

   This threshold is set above the current measurements with a 2x headroom so the bench acts as a
   regression detector without false-positive failures from CI noise. Tighten it once the fast
   parser lands. *)
let alloc_words_threshold = 600.0

let parse_args () =
  let json = ref None in
  let i = ref 1 in
    while !i < Array.length Sys.argv do
      (match Sys.argv.(!i) with
      | "--json" when !i + 1 < Array.length Sys.argv ->
        json := Some Sys.argv.(!i + 1) ;
        incr i
      | "--help" ->
        print_endline "Usage: ingestion_alloc [--json PATH]" ;
        exit 0
      | other ->
        Printf.eprintf "unknown arg: %s\n" other ;
        exit 2) ;
      incr i
    done ;
    !json


let warm_up parse_frame ~symbol_intern frame =
  for _ = 1 to 1000 do
    let _ = parse_frame ~symbol_intern frame in
      ()
  done


let measure_alloc parse_frame ~symbol_intern ~fixture =
  warm_up parse_frame ~symbol_intern fixture ;
  Gc.compact () ;
  let before = Gc.allocated_bytes () in
  let parsed_total = ref 0 in
    for _ = 1 to iters do
      let payloads = parse_frame ~symbol_intern fixture in
        List.iter (fun _ -> incr parsed_total) payloads
    done ;
    let after = Gc.allocated_bytes () in
    let total = after -. before in
    let n = float_of_int (max 1 !parsed_total) in
      total /. n


let main () =
  let json_path = parse_args () in
  let bus = Event_bus.create () in
    Event_bus.start bus ;
    let si = SI.create () in
    let binance_frame =
      {|{"u":1,"s":"BTCUSDT","b":"50000.10","B":"0.5","a":"50000.20","A":"0.7"}|} in
    let coinbase_frame =
      {|{"type":"ticker","sequence":1,"product_id":"BTC-USD","price":"50000.15","best_bid":"50000.10","best_bid_size":"0.5","best_ask":"50000.20","best_ask_size":"0.7","time":"2022-10-19T23:28:22.061769Z"}|}
    in
    let bytes_per_event_b =
      measure_alloc Binance.Parser.parse_frame ~symbol_intern:si ~fixture:binance_frame in
    let bytes_per_event_c =
      measure_alloc Coinbase.Parser.parse_frame ~symbol_intern:si ~fixture:coinbase_frame in
      Event_bus.stop bus ;
      let words_b = bytes_per_event_b /. 8.0 in
      let words_c = bytes_per_event_c /. 8.0 in
        Printf.printf "ingestion_alloc.binance: %.1f bytes/event (%.1f words)\n" bytes_per_event_b
          words_b ;
        Printf.printf "ingestion_alloc.coinbase: %.1f bytes/event (%.1f words)\n" bytes_per_event_c
          words_c ;
        if words_b > alloc_words_threshold || words_c > alloc_words_threshold then (
          Printf.eprintf "REGRESSION: per-event allocation exceeds threshold of %.0f words\n"
            alloc_words_threshold ;
          exit 1) ;
        match json_path with
        | None -> ()
        | Some path ->
          let oc = open_out path in
            Printf.fprintf oc "[\n" ;
            Printf.fprintf oc
              "  \
               {\"name\":\"ingestion.binance.alloc_bytes_per_event\",\"unit\":\"B\",\"value\":%.1f,\"extra\":\"words=%.1f\"},\n"
              bytes_per_event_b words_b ;
            Printf.fprintf oc
              "  \
               {\"name\":\"ingestion.coinbase.alloc_bytes_per_event\",\"unit\":\"B\",\"value\":%.1f,\"extra\":\"words=%.1f\"}\n"
              bytes_per_event_c words_c ;
            Printf.fprintf oc "]\n" ;
            close_out oc ;
            Printf.printf "wrote %s\n" path


let () = main ()
