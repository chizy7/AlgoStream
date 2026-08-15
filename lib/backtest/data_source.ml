module Order_book = Algostream_domain_market.Order_book
module Side = Algostream_strategy.Side
module Event_log = Algostream_infrastructure_event_bus.Event_log
module Event_types = Algostream_infrastructure_event_bus.Event_types
module Bar = Algostream_time_series.Bar
module Timestamp = Algostream_domain_common.Timestamp

type record =
  | Tick of {
      symbol : string;
      ts_ns : int64;
      price : float;
      volume : float;
      bid : float option;
      ask : float option;
    }
  | Trade_print of {
      symbol : string;
      ts_ns : int64;
      price : float;
      size : float;
      aggressor : Side.t option;
    }
  | Book of Order_book.order_book

let ts_ns = function
  | Tick t -> t.ts_ns
  | Trade_print t -> t.ts_ns
  | Book b -> Timestamp.to_ns b.Order_book.timestamp


let symbol = function
  | Tick t -> t.symbol
  | Trade_print t -> t.symbol
  | Book b -> b.Order_book.symbol


type source =
  | Event_log_file of {
      path : string;
      symbols : string list option;
      lo : int64 option;
      hi : int64 option;
    }
  | In_memory of record array
  | Concat of source list

type t = {
  source : source;
  mutable dropped : int;
}

let of_event_log ~path ?symbols ?lo_ts_ns ?hi_ts_ns () =
  { source = Event_log_file { path; symbols; lo = lo_ts_ns; hi = hi_ts_ns }; dropped = 0 }


let of_records records =
  let a = Array.copy records in
  (* Stable sort: records sharing a timestamp keep input order, which is what makes a synthetic
     multi-symbol path reproducible. *)
  let idx = Array.mapi (fun i r -> (ts_ns r, i, r)) a in
    Array.sort
      (fun (t1, i1, _) (t2, i2, _) -> if t1 = t2 then compare i1 i2 else Int64.compare t1 t2)
      idx ;
    { source = In_memory (Array.map (fun (_, _, r) -> r) idx); dropped = 0 }


let of_bars bars =
  of_records
    (Array.map
       (fun (b : Bar.t) ->
         Tick
           {
             symbol = b.Bar.symbol;
             ts_ns = b.Bar.close_ts;
             price = b.Bar.close;
             volume = b.Bar.volume;
             bid = None;
             ask = None;
           })
       bars)


let concat ts = { source = Concat (List.map (fun t -> t.source) ts); dropped = 0 }

let in_window ~lo ~hi ts =
  (match lo with Some l -> Int64.compare ts l >= 0 | None -> true)
  && match hi with Some h -> Int64.compare ts h <= 0 | None -> true


let symbol_wanted ~symbols s =
  match symbols with None -> true | Some ss -> List.exists (String.equal s) ss


(* Payload → record. Market_tick carries a mid plus both sides; Trade_print is a tape print, which
   the fill engine needs separately for queue-position decrementing. *)
let record_of_payload (p : Event_types.Event.payload) =
  match p with
  | Event_types.Event.Market_tick { symbol; timestamp_ns; price; volume; bid; ask } ->
    Some
      (Tick
         {
           symbol;
           ts_ns = timestamp_ns;
           price;
           volume;
           bid = (if bid > 0.0 then Some bid else None);
           ask = (if ask > 0.0 then Some ask else None);
         })
  | Event_types.Event.Trade_print { symbol; price; size; side; timestamp_ns; _ } ->
    let aggressor =
      match side with "buy" -> Some Side.Buy | "sell" -> Some Side.Sell | _ -> None in
      Some (Trade_print { symbol; ts_ns = timestamp_ns; price; size; aggressor })
  | _ -> None


let rec iter_source source ~f =
  match source with
  | In_memory a ->
    Array.iter f a ;
    Array.length a
  | Concat srcs -> List.fold_left (fun acc s -> acc + iter_source s ~f) 0 srcs
  | Event_log_file { path; symbols; lo; hi } ->
    let reader = Event_log.Reader.open_ path in
    let delivered = ref 0 in
    let handle (e : Event_types.Event.t) =
      match record_of_payload e.payload with
      | None -> ()
      | Some r ->
        if in_window ~lo ~hi (ts_ns r) && symbol_wanted ~symbols (symbol r) then (
          incr delivered ;
          f r) in
    let _ = Event_log.Reader.iter reader handle in
      Event_log.Reader.close reader ;
      !delivered


let iter t ~f =
  let last = ref Int64.min_int in
  let dropped = ref 0 in
  let delivered = ref 0 in
  let guarded r =
    let ts = ts_ns r in
      (* Never rewind. Same policy as Pairs.Processor's out_of_order_drops. *)
      if Int64.compare ts !last < 0 then incr dropped
      else (
        last := ts ;
        incr delivered ;
        f r) in
  let _ = iter_source t.source ~f:guarded in
    t.dropped <- !dropped ;
    !delivered


let out_of_order_dropped t = t.dropped

let to_array t =
  let acc = ref [] in
  let _ = iter t ~f:(fun r -> acc := r :: !acc) in
    Array.of_list (List.rev !acc)


let symbols t =
  let seen = Hashtbl.create 16 in
  let order = ref [] in
  let _ =
    iter t ~f:(fun r ->
      let s = symbol r in
        if not (Hashtbl.mem seen s) then (
          Hashtbl.replace seen s () ;
          order := s :: !order)) in
    List.rev !order
