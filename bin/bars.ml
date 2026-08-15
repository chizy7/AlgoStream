(** algostream-bars — replay an event_log into OHLCV bars and print as CSV.

    Usage: algostream-bars --log path/to/log.bin --interval 1s [--symbol BTCUSDT]

    Reads the bin_prot Event log (v3), feeds Market_tick / Trade_print payloads through a
    [Bar_builder.t] per (symbol, interval), and emits CSV rows on stdout. Time arithmetic uses only
    [tick.timestamp_ns] — replay is bit-deterministic across runs. *)

module EB = Algostream_infrastructure_event_bus
module Event_log = EB.Event_log
module Event_types = EB.Event_types
module BB = Algostream_time_series.Bar_builder
module Bar = Algostream_time_series.Bar

type cli = {
  log_path : string;
  interval_ns : int64;
  filter_symbol : string option;
  print_partial : bool;
}

let parse_interval s =
  let last = String.length s - 1 in
    if last < 0 then failwith "empty interval"
    else
      let suffix = s.[last] in
      let prefix = String.sub s 0 last in
      let multiplier =
        match suffix with
        | 's' -> 1_000_000_000L
        | 'm' -> 60_000_000_000L
        | 'h' -> 3_600_000_000_000L
        | _ -> failwith "interval must end in s|m|h" in
        Int64.mul (Int64.of_string prefix) multiplier


let parse_argv () =
  let log_path = ref None in
  let interval = ref "1s" in
  let symbol = ref None in
  let print_partial = ref false in
  let i = ref 1 in
    while !i < Array.length Sys.argv do
      (match Sys.argv.(!i) with
      | "--log" when !i + 1 < Array.length Sys.argv ->
        log_path := Some Sys.argv.(!i + 1) ;
        incr i
      | "--interval" when !i + 1 < Array.length Sys.argv ->
        interval := Sys.argv.(!i + 1) ;
        incr i
      | "--symbol" when !i + 1 < Array.length Sys.argv ->
        symbol := Some Sys.argv.(!i + 1) ;
        incr i
      | "--print-partial" -> print_partial := true
      | "--help" | "-h" ->
        print_endline
          "Usage: algostream-bars --log PATH --interval {1s|1m|5m|1h} [--symbol SYM] \
           [--print-partial]" ;
        exit 0
      | other ->
        Printf.eprintf "unknown arg: %s\n" other ;
        exit 2) ;
      incr i
    done ;
    let log_path =
      match !log_path with
      | Some p -> p
      | None ->
        Printf.eprintf "missing --log\n" ;
        exit 2 in
      {
        log_path;
        interval_ns = parse_interval !interval;
        filter_symbol = !symbol;
        print_partial = !print_partial;
      }


let main () =
  let cli = parse_argv () in
  let builders : (string, BB.t) Hashtbl.t = Hashtbl.create 16 in
  let print_bar b = print_endline (Bar.to_csv_row b) in
    print_endline "symbol,open_ts,close_ts,open,high,low,close,volume,n_ticks,partial" ;
    let reader = Event_log.Reader.open_ cli.log_path in
    let _count =
      Event_log.Reader.iter reader (fun (ev : Event_types.Event.t) ->
        let consume ~symbol ~ts ~price ~size =
          let pass_symbol =
            match cli.filter_symbol with None -> true | Some s -> String.equal s symbol in
            if pass_symbol then
              let bb =
                match Hashtbl.find_opt builders symbol with
                | Some b -> b
                | None ->
                  let b = BB.create ~symbol ~interval_ns:cli.interval_ns in
                    Hashtbl.add builders symbol b ;
                    b in
                match BB.on_tick bb ~ts ~price ~size with None -> () | Some b -> print_bar b in
          match ev.payload with
          | Event_types.Event.Market_tick { symbol; timestamp_ns; price; volume; _ } ->
            consume ~symbol ~ts:timestamp_ns ~price ~size:volume
          | Event_types.Event.Trade_print { symbol; timestamp_ns; price; size; _ } ->
            consume ~symbol ~ts:timestamp_ns ~price ~size
          | _ -> ()) in
      Event_log.Reader.close reader ;
      if cli.print_partial then
        Hashtbl.iter
          (fun _sym bb -> match BB.flush bb with None -> () | Some b -> print_bar b)
          builders


let () = main ()
