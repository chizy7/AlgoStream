module Tracker = struct
  type t = {
    mutable peak : float;
    mutable current_dd : float;
    mutable max_dd : float;
    mutable last_ts_ns : int64;
    mutable under_water_since_ns : int64;
    (* Int64.min_int = sentinel "not under water" *)
    mutable n : int;
  }

  let create ?(initial_equity = 0.0) () =
    {
      peak = initial_equity;
      current_dd = 0.0;
      max_dd = 0.0;
      last_ts_ns = 0L;
      under_water_since_ns = Int64.min_int;
      n = 0;
    }


  let update t ~equity ~ts_ns =
    if Int64.compare ts_ns t.last_ts_ns < 0 then ()
    else (
      t.last_ts_ns <- ts_ns ;
      t.n <- t.n + 1 ;
      if equity > t.peak then (
        t.peak <- equity ;
        t.current_dd <- 0.0 ;
        t.under_water_since_ns <- Int64.min_int)
      else
        let dd = if t.peak > 0.0 then max 0.0 ((t.peak -. equity) /. t.peak) else 0.0 in
          t.current_dd <- dd ;
          if dd > t.max_dd then t.max_dd <- dd ;
          if dd > 0.0 && Int64.equal t.under_water_since_ns Int64.min_int then
            t.under_water_since_ns <- ts_ns)


  let peak_equity t = t.peak

  let current_drawdown t = t.current_dd

  let max_drawdown t = t.max_dd

  let time_under_water_ns t =
    if Int64.equal t.under_water_since_ns Int64.min_int then 0L
    else Int64.sub t.last_ts_ns t.under_water_since_ns


  let n_updates t = t.n
end
