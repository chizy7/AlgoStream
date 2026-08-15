(** algostream-ingest — public market-data ingestion CLI.

    Spins up the event bus + ingestion supervisor, runs for [--duration] seconds (or until SIGINT),
    optionally captures every event to a binary log via {!Event_log.Writer}, then prints
    per-exchange stats. *)

module EB = Algostream_infrastructure_event_bus
module Event_bus = EB.Event_bus
module Event_log = EB.Event_log
module Exchange_config = Algostream_common_config.Exchange_config
module Ingestion = Algostream_data_ingestion.Ingestion_supervisor
module Binance = Algostream_data_ingestion_binance
module Coinbase = Algostream_data_ingestion_coinbase

type cli = {
  exchange : string;
  symbols : string list;
  duration_s : int;
  config_file : string option;
  log_output : string option;
  print_events : bool;
}

let usage =
  "Usage: algostream-ingest --exchange {binance|coinbase|both} --symbols S1,S2,... [--duration \
   SECONDS] [--config FILE] [--log-output PATH] [--print-events]\n\
  \  --exchange     Which connector(s) to start. \"both\" runs Binance + Coinbase.\n\
  \  --symbols      Comma-separated exchange-native symbols (e.g. BTCUSDT for Binance, BTC-USD for \
   Coinbase).\n\
  \  --duration     How many seconds to run before stopping (default: 60). 0 = run forever.\n\
  \  --config       JSON config file overriding defaults.\n\
  \  --log-output   Optional path to write a binary event log for offline replay.\n\
  \  --print-events Echo every Market_tick / Trade_print to stdout."


let parse_argv () =
  let exchange = ref "both" in
  let symbols = ref "" in
  let duration_s = ref 60 in
  let config_file = ref None in
  let log_output = ref None in
  let print_events = ref false in
  let rec loop i =
    if i >= Array.length Sys.argv then ()
    else
      match Sys.argv.(i) with
      | "--exchange" when i + 1 < Array.length Sys.argv ->
        exchange := Sys.argv.(i + 1) ;
        loop (i + 2)
      | "--symbols" when i + 1 < Array.length Sys.argv ->
        symbols := Sys.argv.(i + 1) ;
        loop (i + 2)
      | "--duration" when i + 1 < Array.length Sys.argv ->
        duration_s := int_of_string Sys.argv.(i + 1) ;
        loop (i + 2)
      | "--config" when i + 1 < Array.length Sys.argv ->
        config_file := Some Sys.argv.(i + 1) ;
        loop (i + 2)
      | "--log-output" when i + 1 < Array.length Sys.argv ->
        log_output := Some Sys.argv.(i + 1) ;
        loop (i + 2)
      | "--print-events" ->
        print_events := true ;
        loop (i + 1)
      | "--help" | "-h" ->
        print_endline usage ;
        exit 0
      | other ->
        Printf.eprintf "unknown arg: %s\n%s\n" other usage ;
        exit 2 in
    loop 1 ;
    let symbol_list =
      String.split_on_char ',' !symbols |> List.map String.trim |> List.filter (fun s -> s <> "")
    in
      {
        exchange = !exchange;
        symbols = symbol_list;
        duration_s = !duration_s;
        config_file = !config_file;
        log_output = !log_output;
        print_events = !print_events;
      }


let resolve_entries cli : Ingestion.entry list =
  match cli.config_file with
  | Some path ->
    (match Exchange_config.load_file path with
    | Ok configs ->
      List.filter_map
        (fun (cfg : Exchange_config.t) ->
          match cfg.name with
          | "binance" -> Some Ingestion.{ em = (module Binance.Connector); config = cfg }
          | "coinbase" -> Some Ingestion.{ em = (module Coinbase.Connector); config = cfg }
          | other ->
            Printf.eprintf "warning: unknown exchange in config: %s (skipping)\n" other ;
            None)
        configs
    | Error e ->
      Printf.eprintf "config error: %s\n" e ;
      exit 2)
  | None ->
    let symbols = cli.symbols in
      if symbols = [] then (
        Printf.eprintf "no --symbols supplied\n%s\n" usage ;
        exit 2) ;
      let binance_cfg = Exchange_config.binance_default ~symbols in
      let coinbase_cfg = Exchange_config.coinbase_default ~symbols in
        (match cli.exchange with
        | "binance" -> [ Ingestion.{ em = (module Binance.Connector); config = binance_cfg } ]
        | "coinbase" -> [ Ingestion.{ em = (module Coinbase.Connector); config = coinbase_cfg } ]
        | "both" ->
          [
            Ingestion.{ em = (module Binance.Connector); config = binance_cfg };
            Ingestion.{ em = (module Coinbase.Connector); config = coinbase_cfg };
          ]
        | other ->
          Printf.eprintf "unknown exchange: %s\n%s\n" other usage ;
          exit 2)


let format_payload p =
  match (p : EB.Event_types.Event.payload) with
  | Market_tick { symbol; price; volume; bid; ask; _ } ->
    Printf.sprintf "MKT %s mid=%g bid=%g ask=%g vol=%g" symbol price bid ask volume
  | Trade_print { symbol; price; size; side; _ } ->
    Printf.sprintf "TRD %s %s %g @ %g" symbol side size price
  | Risk_alert { code; message; _ } -> Printf.sprintf "RISK %s %s" code message
  | Data_gap { symbol; expected_seq; received_seq; dropped_count; _ } ->
    Printf.sprintf "GAP %s expected=%Ld received=%Ld dropped=%d" symbol expected_seq received_seq
      dropped_count
  | Heartbeat -> "HB"
  | _ -> "<other>"


let install_logs () =
  Logs.set_reporter (Logs.format_reporter ()) ;
  Logs.set_level (Some Logs.Info)


let print_stats stats_list =
  List.iter
    (fun (s : Ingestion.per_exchange_stats) ->
      let dq = s.data_quality in
        Printf.printf
          "[%s] observed=%d gaps=%d dropped_to_gap=%d stale=%d crossed=%d ooo=%d bus_drops=%Ld \
           critical_drops=%Ld\n"
          s.exchange dq.total_observed dq.sequence_gaps dq.dropped_to_gap dq.stale_ticks
          dq.crossed_books dq.out_of_order_trades s.bus_drops s.critical_drops)
    stats_list


let main () =
  let cli = parse_argv () in
    install_logs () ;
    let bus = Event_bus.create ~capacity_per_band:65536 () in
      Event_bus.start bus ;
      let log_writer = Option.map Event_log.Writer.create cli.log_output in
      let log_subscriber =
        Option.map
          (fun w -> Event_bus.subscribe bus (fun ev -> Event_log.Writer.append w ev))
          log_writer in
        if cli.print_events then
          ignore
            (Event_bus.subscribe bus (fun ev -> print_endline (format_payload ev.payload))
              : EB.Subscription.subscription_id) ;
        let entries = resolve_entries cli in
          if entries = [] then (
            Printf.eprintf "no exchanges to start\n" ;
            exit 2) ;
          let supervisor = Ingestion.start ~bus ~entries () in
          let stop_now = ref false in
          let _ =
            Sys.set_signal Sys.sigint
              (Sys.Signal_handle
                 (fun _ ->
                   stop_now := true ;
                   Printf.printf "\nSIGINT received — stopping...\n%!")) in
          let started_at = Unix.gettimeofday () in
          let deadline =
            if cli.duration_s = 0 then infinity else started_at +. float_of_int cli.duration_s in
            while (not !stop_now) && Unix.gettimeofday () < deadline do
              Unix.sleepf 0.5
            done ;
            let stats = Ingestion.stop supervisor in
              Option.iter (Event_bus.unsubscribe bus) log_subscriber ;
              Option.iter Event_log.Writer.close log_writer ;
              Event_bus.stop bus ;
              Printf.printf "\n=== ingestion stats ===\n" ;
              print_stats stats


let () = main ()
