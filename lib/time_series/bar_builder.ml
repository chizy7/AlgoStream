type t = {
  symbol : string;
  interval_ns : int64;
  mutable cur_open_ts : int64; (* Int64.min_int = "no current bar yet" *)
  mutable cur_o : float;
  mutable cur_h : float;
  mutable cur_l : float;
  mutable cur_c : float;
  mutable cur_v : float;
  mutable cur_n : int;
  mutable late_ticks : int;
}

let create ~symbol ~interval_ns =
  {
    symbol;
    interval_ns;
    cur_open_ts = Int64.min_int;
    cur_o = 0.0;
    cur_h = 0.0;
    cur_l = 0.0;
    cur_c = 0.0;
    cur_v = 0.0;
    cur_n = 0;
    late_ticks = 0;
  }


let symbol t = t.symbol

let interval_ns t = t.interval_ns

let late_tick_count t = t.late_ticks

let bar_open_for ts ~interval =
  (* floor(ts / interval) * interval, handling negative ts via OCaml's int64 div semantics
     (truncates toward zero — so we handle pre-1970 timestamps explicitly). *)
  if Int64.compare ts 0L >= 0 then Int64.mul (Int64.div ts interval) interval
  else
    let q = Int64.div ts interval in
    let r = Int64.rem ts interval in
      if Int64.compare r 0L = 0 then Int64.mul q interval else Int64.mul (Int64.sub q 1L) interval


let snapshot t : Bar.t =
  {
    symbol = t.symbol;
    open_ts = t.cur_open_ts;
    close_ts = Int64.add t.cur_open_ts t.interval_ns;
    open_ = t.cur_o;
    high = t.cur_h;
    low = t.cur_l;
    close = t.cur_c;
    volume = t.cur_v;
    n_ticks = t.cur_n;
    partial = false;
  }


let open_bar t ~ts ~price ~size =
  t.cur_open_ts <- ts ;
  t.cur_o <- price ;
  t.cur_h <- price ;
  t.cur_l <- price ;
  t.cur_c <- price ;
  t.cur_v <- size ;
  t.cur_n <- 1


let on_tick t ~ts ~price ~size =
  if Int64.equal t.cur_open_ts Int64.min_int then (
    let bar_open = bar_open_for ts ~interval:t.interval_ns in
      open_bar t ~ts:bar_open ~price ~size ;
      None)
  else
    let cur_close = Int64.add t.cur_open_ts t.interval_ns in
      if Int64.compare ts cur_close >= 0 then (
        let emitted = snapshot t in
        let bar_open = bar_open_for ts ~interval:t.interval_ns in
          open_bar t ~ts:bar_open ~price ~size ;
          Some emitted)
      else if Int64.compare ts t.cur_open_ts < 0 then (
        t.late_ticks <- t.late_ticks + 1 ;
        None)
      else (
        (* in-bar update *)
        if price > t.cur_h then t.cur_h <- price ;
        if price < t.cur_l then t.cur_l <- price ;
        t.cur_c <- price ;
        t.cur_v <- t.cur_v +. size ;
        t.cur_n <- t.cur_n + 1 ;
        None)


let flush t =
  if t.cur_n = 0 || Int64.equal t.cur_open_ts Int64.min_int then None
  else
    let snap = snapshot t in
      Some { snap with partial = true }
