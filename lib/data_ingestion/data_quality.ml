type stats = {
  total_observed : int;
  sequence_gaps : int;
  dropped_to_gap : int;
  stale_ticks : int;
  crossed_books : int;
  out_of_order_trades : int;
}

type per_symbol = {
  mutable last_sequence : int64;
  mutable last_trade_id_seq : int64;
}

type t = {
  exchange : string;
  stale_threshold_ns : int64;
  ticks : (string, per_symbol) Hashtbl.t;
  trades : (string, per_symbol) Hashtbl.t;
  mutable total_observed : int;
  mutable sequence_gaps : int;
  mutable dropped_to_gap : int;
  mutable stale_ticks : int;
  mutable crossed_books : int;
  mutable out_of_order_trades : int;
}

type verdict =
  | Ok_publish
  | Drop_stale of { age_ns : int64 }
  | Drop_crossed of {
      bid : float;
      ask : float;
    }
  | Out_of_order
  | Gap_then_publish of {
      expected : int64;
      received : int64;
      dropped : int;
    }

let create ~exchange ?(stale_threshold_ns = 1_000_000_000L) () =
  {
    exchange;
    stale_threshold_ns;
    ticks = Hashtbl.create 16;
    trades = Hashtbl.create 16;
    total_observed = 0;
    sequence_gaps = 0;
    dropped_to_gap = 0;
    stale_ticks = 0;
    crossed_books = 0;
    out_of_order_trades = 0;
  }


let exchange_name t = t.exchange

let lookup tbl symbol =
  match Hashtbl.find_opt tbl symbol with
  | Some s -> s
  | None ->
    let s = { last_sequence = -1L; last_trade_id_seq = -1L } in
      Hashtbl.add tbl symbol s ;
      s


(* Detect a sequence gap. Returns the verdict mutation if a gap was observed. Updates state. *)
let check_sequence ~field state ~received =
  let prev = match field with `Tick -> state.last_sequence | `Trade -> state.last_trade_id_seq in
  let v =
    if Int64.compare prev 0L < 0 then Ok_publish
    else if Int64.compare received prev <= 0 then
      (* regression — covered separately by callers *)
      Ok_publish
    else
      let expected = Int64.add prev 1L in
        if Int64.compare received expected = 0 then Ok_publish
        else
          let dropped = Int64.to_int (Int64.sub received expected) in
            Gap_then_publish { expected; received; dropped } in
    (match field with
    | `Tick -> state.last_sequence <- received
    | `Trade -> state.last_trade_id_seq <- received) ;
    v


(* Fold a gap verdict into the counters. Shared so the two entry points cannot drift on which of
   sequence_gaps / dropped_to_gap they bump. *)
let count_gap t v =
  match v with
  | Gap_then_publish g ->
    t.sequence_gaps <- t.sequence_gaps + 1 ;
    t.dropped_to_gap <- t.dropped_to_gap + g.dropped ;
    v
  | other -> other


let check_market_tick t ~symbol ~exchange_ts_ns ~ingest_ts_ns ~bid ~ask ~sequence =
  t.total_observed <- t.total_observed + 1 ;
  if bid > ask && bid > 0.0 && ask > 0.0 then (
    t.crossed_books <- t.crossed_books + 1 ;
    Drop_crossed { bid; ask })
  else
    let age = Int64.sub ingest_ts_ns exchange_ts_ns in
      if Int64.compare age t.stale_threshold_ns > 0 then (
        t.stale_ticks <- t.stale_ticks + 1 ;
        Drop_stale { age_ns = age })
      else
        match sequence with
        | None -> Ok_publish
        | Some received ->
          let state = lookup t.ticks symbol in
            count_gap t (check_sequence ~field:`Tick state ~received)


let check_trade_print t ~symbol ~exchange_ts_ns ~ingest_ts_ns ~sequence =
  t.total_observed <- t.total_observed + 1 ;
  let _age = Int64.sub ingest_ts_ns exchange_ts_ns in
  let _ = _age in
    match sequence with
    | None -> Ok_publish
    | Some received ->
      let state = lookup t.trades symbol in
        if Int64.compare received 0L >= 0 && Int64.compare state.last_trade_id_seq received > 0 then (
          t.out_of_order_trades <- t.out_of_order_trades + 1 ;
          Out_of_order)
        else count_gap t (check_sequence ~field:`Trade state ~received)


let stats t =
  {
    total_observed = t.total_observed;
    sequence_gaps = t.sequence_gaps;
    dropped_to_gap = t.dropped_to_gap;
    stale_ticks = t.stale_ticks;
    crossed_books = t.crossed_books;
    out_of_order_trades = t.out_of_order_trades;
  }
