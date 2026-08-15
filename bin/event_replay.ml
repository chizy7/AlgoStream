(** Replay an event log into a fresh event bus. *)

module EB = Algostream_infrastructure_event_bus

let usage () =
  prerr_endline
    "Usage: event_replay --log-file PATH [--speed N] [--print]\n\n\
    \  --log-file PATH  Path to the binary event log to replay.\n\
    \  --speed N        Replay speed multiplier (default: as fast as possible).\n\
    \                   1.0 = real-time, 10.0 = 10x faster.\n\
    \  --print          Subscribe a default printer that logs each event.\n" ;
  exit 2


let parse_args argv =
  let log_file = ref None in
  let speed = ref Float.infinity in
  let print_events = ref false in
  let i = ref 1 in
    while !i < Array.length argv do
      (match argv.(!i) with
      | "--log-file" when !i + 1 < Array.length argv ->
        log_file := Some argv.(!i + 1) ;
        incr i
      | "--speed" when !i + 1 < Array.length argv ->
        speed := Float.of_string argv.(!i + 1) ;
        incr i
      | "--print" -> print_events := true
      | "--help" | "-h" -> usage ()
      | other ->
        Printf.eprintf "Unknown argument: %s\n" other ;
        usage ()) ;
      incr i
    done ;
    match !log_file with
    | None ->
      prerr_endline "error: --log-file is required" ;
      usage ()
    | Some f -> (f, !speed, !print_events)


let () =
  let log_file, speed, print_events = parse_args Sys.argv in
  let bus = EB.Event_bus.create () in
    if print_events then
      ignore
        (EB.Event_bus.subscribe bus (fun e ->
           Printf.printf "[seq=%Ld pri=%s src=%s] %s\n%!" e.sequence_id
             (EB.Event_types.Priority.to_string e.priority)
             e.source
             (EB.Event_types.Event.message_type_of_payload e.payload
             |> Algostream_common_utils.Zero_copy.MessageType.to_string))) ;
    EB.Event_bus.start bus ;
    let n = EB.Event_log.replay bus ~path:log_file ~speed () in
      (* Give the dispatcher a moment to drain remaining events. *)
      Algostream_common_utils.Time_utils.Sleep.sleep_ms 100L ;
      EB.Event_bus.stop bus ;
      Printf.printf "Replayed %d events from %s\n" n log_file ;
      let stats = EB.Event_bus.stats bus in
        print_endline (EB.Instrumentation.pp_stats stats)
