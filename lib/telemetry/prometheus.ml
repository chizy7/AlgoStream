let content_type = "text/plain; version=0.0.4; charset=utf-8"

let prefix = "algostream_"

let sanitise s =
  let b = Buffer.create (String.length s + 8) in
    String.iter
      (fun c ->
        match c with
        | 'a' .. 'z' | 'A' .. 'Z' | '0' .. '9' | '_' -> Buffer.add_char b c
        | '.' | '-' | ' ' | '/' -> Buffer.add_char b '_'
        | _ -> ())
      s ;
    Buffer.contents b


let metric_name key =
  let s = sanitise key in
    (* A name must not start with a digit. *)
    if String.length s > 0 && s.[0] >= '0' && s.[0] <= '9' then prefix ^ "_" ^ s else prefix ^ s


(* Cumulative and monotonic → counter. Guessing from the value would misclassify a counter that
   happens to be zero, and a wrong type makes rate() nonsense rather than merely untidy. *)
let counter_suffixes =
  [
    "published";
    "dropped";
    "dispatched";
    "handler_errors";
    "errors";
    "violations";
    "count";
    "observed";
    "processed";
    "emitted";
    "drops";
    "gaps";
    "evictions";
    "rejected";
    "bars";
    "bus_drops";
    "critical_drops";
    "sequence_gaps";
    "stale_ticks";
    "crossed_books";
    "events";
    "fills";
    "trades";
  ]


let ends_with ~suffix s =
  let ls = String.length s and lf = String.length suffix in
    ls >= lf && String.equal (String.sub s (ls - lf) lf) suffix


let kind_of key =
  let k = String.lowercase_ascii key in
    if List.exists (fun suf -> ends_with ~suffix:suf k) counter_suffixes then "counter" else "gauge"


(* Prometheus wants a bare decimal; OCaml's %f would print "inf" and "nan", which a scrape rejects.
   Non-finite values become 0 rather than being dropped, so a series does not silently disappear the
   moment something divides by zero. *)
let format_value v =
  if Float.is_nan v then "0"
  else if Float.is_integer v && Float.abs v < 1e15 then Printf.sprintf "%.0f" v
  else if not (Float.is_finite v) then if v > 0.0 then "+Inf" else "-Inf"
  else Printf.sprintf "%g" v


let render (s : Snapshot.t) =
  let b = Buffer.create 4096 in
  let seen = Hashtbl.create 64 in
  let emit key value =
    let base = metric_name key in
    (* Two different snapshot keys can sanitise to the same name. Merging them into one series would
       silently lose data, so disambiguate instead. *)
    let name =
      match Hashtbl.find_opt seen base with
      | None ->
        Hashtbl.replace seen base 1 ;
        base
      | Some n ->
        Hashtbl.replace seen base (n + 1) ;
        Printf.sprintf "%s_%d" base (n + 1) in
      Buffer.add_string b (Printf.sprintf "# HELP %s %s\n" name key) ;
      Buffer.add_string b (Printf.sprintf "# TYPE %s %s\n" name (kind_of key)) ;
      Buffer.add_string b (Printf.sprintf "%s %s\n" name (format_value value)) in
    List.iter (fun (k, v) -> emit k v) (Snapshot.to_assoc s) ;
    (* Three series [Snapshot.to_assoc] cannot express, because it is numeric-only.

       [health_state] and [alerts_active] come off the snapshot's non-numeric fields. Overall health
       is the single most basic thing to alert on, so leaving it unexportable because the enum is
       not a float would be a poor trade.

       [heap_bytes] is process-level rather than snapshot-level, read straight from the runtime.
       [quick_stat] rather than [stat] deliberately: [stat] walks the major heap, which on a scrape
       every fifteen seconds would make the exporter a source of the pauses it is meant to
       measure. *)
    emit "health_state"
      (match s.Snapshot.overall with
      | Health.Ok -> 0.0
      | Health.Degraded _ -> 1.0
      | Health.Failed _ -> 2.0) ;
    emit "alerts_active" (float_of_int (List.length s.Snapshot.alerts)) ;
    let gc = Gc.quick_stat () in
      emit "heap_bytes" (float_of_int (gc.Gc.heap_words * (Sys.word_size / 8))) ;
      Buffer.contents b
