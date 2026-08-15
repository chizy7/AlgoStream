(** Ingestion throughput benchmark.

    Measures parser + bus-publish throughput on pre-decoded fixture frames. Loads recorded JSON
    samples once into a [string array], then loops [iters] times to amortize warm-up. Emits the
    customSmallerIsBetter schema for github-action-benchmark. No network. *)

module EB = Algostream_infrastructure_event_bus
module Event_bus = EB.Event_bus
module Event_types = EB.Event_types
module SI = Algostream_data_ingestion.Symbol_intern
module Binance = Algostream_data_ingestion_binance
module Coinbase = Algostream_data_ingestion_coinbase
module Clock = Algostream_common_utils.Time_utils.Clock
module Sleep = Algostream_common_utils.Time_utils.Sleep

let iters = 1_000_000

let parse_args () =
  let json = ref None in
  let i = ref 1 in
    while !i < Array.length Sys.argv do
      (match Sys.argv.(!i) with
      | "--json" when !i + 1 < Array.length Sys.argv ->
        json := Some Sys.argv.(!i + 1) ;
        incr i
      | "--help" ->
        print_endline "Usage: ingestion_throughput [--json PATH]" ;
        exit 0
      | other ->
        Printf.eprintf "unknown arg: %s\n" other ;
        exit 2) ;
      incr i
    done ;
    !json


let read_lines path =
  if not (Sys.file_exists path) then [||]
  else
    let ic = open_in path in
    let lines = ref [] in
      (try
         while true do
           lines := input_line ic :: !lines
         done
       with End_of_file -> ()) ;
      close_in ic ;
      !lines |> List.rev |> Array.of_list


let load_fixtures () =
  let here = Filename.dirname Sys.executable_name in
  let candidates =
    [
      Filename.concat here "../../../test/mocks/exchange";
      "test/mocks/exchange";
      Filename.concat (Sys.getcwd ()) "test/mocks/exchange";
    ] in
  let dir =
    match List.find_opt Sys.file_exists candidates with
    | Some d -> d
    | None ->
      Printf.eprintf "warning: fixture dir not found; benchmark uses inline samples\n" ;
      "" in
  let load name = if dir = "" then [||] else read_lines (Filename.concat dir name) in
  let binance = Array.append (load "binance_bookticker.jsonl") (load "binance_trade.jsonl") in
  let coinbase = Array.append (load "coinbase_ticker.jsonl") (load "coinbase_match.jsonl") in
    (binance, coinbase)


let inline_binance_fallback =
  [|
    {|{"u":1,"s":"BTCUSDT","b":"50000.10","B":"0.5","a":"50000.20","A":"0.7"}|};
    {|{"e":"trade","E":1591241801500,"s":"BTCUSDT","t":12345,"p":"50000.15","q":"0.01","b":88,"a":50,"T":1591241801499,"m":true,"M":true}|};
  |]


let inline_coinbase_fallback =
  [|
    {|{"type":"ticker","sequence":1,"product_id":"BTC-USD","price":"50000.15","best_bid":"50000.10","best_bid_size":"0.5","best_ask":"50000.20","best_ask_size":"0.7","time":"2022-10-19T23:28:22.061769Z"}|};
    {|{"type":"match","trade_id":1,"sequence":2,"product_id":"BTC-USD","price":"50000.15","size":"0.01","side":"buy","time":"2022-10-19T23:28:22.061769Z"}|};
  |]


let bench_one ~name ~bus ~parse ~symbol_intern ~fixtures =
  let n_fix = Array.length fixtures in
    if n_fix = 0 then (0L, 0)
    else
      let t0 = Clock.now_monotonic_ns () in
      let parsed_count = ref 0 in
        for i = 0 to iters - 1 do
          let frame = fixtures.(i mod n_fix) in
          let payloads = parse ~symbol_intern frame in
            List.iter
              (fun payload ->
                let event =
                  Event_types.Event.create ~source:name ~priority:Event_types.Priority.Normal
                    payload in
                  ignore (Event_bus.try_publish bus event : bool) ;
                  incr parsed_count)
              payloads
        done ;
        let t1 = Clock.now_monotonic_ns () in
          (Int64.sub t1 t0, !parsed_count)


let main () =
  let json_path = parse_args () in
  let bus = Event_bus.create ~capacity_per_band:65536 () in
    Event_bus.start bus ;
    (* Drain subscriber so the bus actually completes work — avoid bench-only enqueue speedup. *)
    let recv = Atomic.make 0 in
    let _ = Event_bus.subscribe bus (fun _ -> Atomic.incr recv) in
    let binance_fixtures, coinbase_fixtures = load_fixtures () in
    let binance_fixtures =
      if Array.length binance_fixtures = 0 then inline_binance_fallback else binance_fixtures in
    let coinbase_fixtures =
      if Array.length coinbase_fixtures = 0 then inline_coinbase_fallback else coinbase_fixtures
    in
    let si = SI.create () in
    let elapsed_b, parsed_b =
      bench_one ~name:"binance" ~bus ~parse:Binance.Parser.parse_frame ~symbol_intern:si
        ~fixtures:binance_fixtures in
    let elapsed_c, parsed_c =
      bench_one ~name:"coinbase" ~bus ~parse:Coinbase.Parser.parse_frame ~symbol_intern:si
        ~fixtures:coinbase_fixtures in
    let drain_deadline = Int64.add (Clock.now_monotonic_ns ()) 5_000_000_000L in
      while Atomic.get recv < parsed_b + parsed_c && Clock.now_monotonic_ns () < drain_deadline do
        Sleep.sleep_us 100L
      done ;
      Event_bus.stop bus ;
      let ns_per_event_b =
        if parsed_b = 0 then 0L else Int64.div elapsed_b (Int64.of_int parsed_b) in
      let ns_per_event_c =
        if parsed_c = 0 then 0L else Int64.div elapsed_c (Int64.of_int parsed_c) in
      let ev_per_sec n elapsed_ns =
        if Int64.compare elapsed_ns 0L = 0 then 0.0
        else float_of_int n /. (Int64.to_float elapsed_ns /. 1_000_000_000.0) in
      let tput_b = ev_per_sec parsed_b elapsed_b in
      let tput_c = ev_per_sec parsed_c elapsed_c in
        Printf.printf
          "ingestion_throughput.binance: parsed=%d elapsed=%Ldns ns/ev=%Ld throughput=%.0f ev/s\n"
          parsed_b elapsed_b ns_per_event_b tput_b ;
        Printf.printf
          "ingestion_throughput.coinbase: parsed=%d elapsed=%Ldns ns/ev=%Ld throughput=%.0f ev/s\n"
          parsed_c elapsed_c ns_per_event_c tput_c ;
        match json_path with
        | None -> ()
        | Some path ->
          let oc = open_out path in
            Printf.fprintf oc "[\n" ;
            Printf.fprintf oc
              "  \
               {\"name\":\"ingestion.binance.ns_per_event\",\"unit\":\"ns\",\"value\":%Ld,\"extra\":\"throughput=%.0f \
               ev/s\"},\n"
              ns_per_event_b tput_b ;
            Printf.fprintf oc
              "  \
               {\"name\":\"ingestion.coinbase.ns_per_event\",\"unit\":\"ns\",\"value\":%Ld,\"extra\":\"throughput=%.0f \
               ev/s\"}\n"
              ns_per_event_c tput_c ;
            Printf.fprintf oc "]\n" ;
            close_out oc ;
            Printf.printf "wrote %s\n" path


let () = main ()
