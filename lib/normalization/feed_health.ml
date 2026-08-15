module LM = Algostream_common_utils.Time_utils.LatencyMonitor

type cell = {
  source : string;
  monitor : LM.t;
  mutable ticks : int64;
  mutable gaps : int64;
  mutable last_event_ts_ns : int64;
}

type t = {
  table : (string, cell) Hashtbl.t;
  max_sources : int;
  lock : Mutex.t; (* writes are infrequent; protects evict + add *)
}

type per_source_stats = {
  source : string;
  ticks : int64;
  gaps : int64;
  last_event_ts_ns : int64;
  avg_latency_ns : int64;
  max_latency_ns : int64;
}

let create ?(max_sources = 64) () =
  { table = Hashtbl.create max_sources; max_sources; lock = Mutex.create () }


let evict_lru ~(table : (string, cell) Hashtbl.t) =
  let oldest =
    Hashtbl.fold
      (fun _src (cell : cell) (osrc, ots) ->
        if Int64.compare cell.last_event_ts_ns ots < 0 then (Some cell.source, cell.last_event_ts_ns)
        else (osrc, ots))
      table (None, Int64.max_int) in
    match fst oldest with Some s -> Hashtbl.remove table s | None -> ()


let get_or_create t ~source =
  match Hashtbl.find_opt t.table source with
  | Some c -> c
  | None ->
    Mutex.lock t.lock ;
    let c =
      match Hashtbl.find_opt t.table source with
      | Some c -> c
      | None ->
        if Hashtbl.length t.table >= t.max_sources then evict_lru ~table:t.table ;
        let monitor = LM.create ~window_size:1024 ~violation_threshold_ns:5_000_000L in
        let c = { source; monitor; ticks = 0L; gaps = 0L; last_event_ts_ns = 0L } in
          Hashtbl.add t.table source c ;
          c in
      Mutex.unlock t.lock ;
      c


let observe t ~source ~ts_ns ~latency_ns =
  let c = get_or_create t ~source in
    LM.add_measurement c.monitor latency_ns ;
    c.ticks <- Int64.add c.ticks 1L ;
    c.last_event_ts_ns <- ts_ns


let record_gap t ~source =
  let c = get_or_create t ~source in
    c.gaps <- Int64.add c.gaps 1L


let stats_of_cell (c : cell) =
  {
    source = c.source;
    ticks = c.ticks;
    gaps = c.gaps;
    last_event_ts_ns = c.last_event_ts_ns;
    avg_latency_ns = LM.get_current_avg c.monitor;
    max_latency_ns = LM.get_max_latency c.monitor;
  }


let per_source t ~source =
  match Hashtbl.find_opt t.table source with Some c -> Some (stats_of_cell c) | None -> None


let all t = Hashtbl.fold (fun _ c acc -> stats_of_cell c :: acc) t.table []

let active_count t = Hashtbl.length t.table
