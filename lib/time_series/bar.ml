type t = {
  symbol : string;
  open_ts : int64;
  close_ts : int64;
  open_ : float;
  high : float;
  low : float;
  close : float;
  volume : float;
  n_ticks : int;
  partial : bool;
}

let to_csv_row t =
  Printf.sprintf "%s,%Ld,%Ld,%.10g,%.10g,%.10g,%.10g,%.10g,%d,%b" t.symbol t.open_ts t.close_ts
    t.open_ t.high t.low t.close t.volume t.n_ticks t.partial
