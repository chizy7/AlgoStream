open Base

type timestamp = float [@@deriving sexp, compare, hash]

type time_span = float [@@deriving sexp, compare, hash]

let now () = Unix.time ()

let timestamp_of_float f = f

let span_of_seconds s = s

let span_of_minutes m = m *. 60.0

let span_of_hours h = h *. 3600.0

let span_of_days d = d *. 86400.0

let add_span timestamp span = timestamp +. span

let diff t1 t2 = t1 -. t2

let compare_timestamp = Float.compare

let compare_span = Float.compare
