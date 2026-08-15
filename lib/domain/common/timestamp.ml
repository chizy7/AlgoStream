open Base

(* High-performance timestamp implementation using float seconds since epoch *)
module T = struct
  type t = float [@@deriving sexp, compare, hash]

  let of_float f = f

  let to_float t = t

  let now () = Unix.time ()

  (* Create timestamp from seconds since epoch *)
  let of_sec_float f = f

  (* Create from milliseconds *)
  let of_ms_float ms = ms /. 1000.0

  (* Create from microseconds *)
  let of_us_float us = us /. 1_000_000.0

  (* Create from nanoseconds since epoch — the event-time representation used by the bus, the
     analytics/time_series/pairs layers, and the backtest engine. *)
  let of_ns ns = Int64.to_float ns /. 1_000_000_000.0

  (* Convert to various units *)
  let to_sec_float t = t

  let to_ms_float t = t *. 1000.0

  let to_us_float t = t *. 1_000_000.0

  let to_ns t = Int64.of_float (Float.round_nearest (t *. 1_000_000_000.0))

  (* Formatting *)
  let to_string t = Printf.sprintf "%.6f" t

  let compare = Float.compare
end

include T

(* Span module for time differences *)
module Span = struct
  type t = float [@@deriving sexp, compare, hash]

  let of_sec f = f

  let of_min f = f *. 60.0

  let of_hr f = f *. 3600.0

  let of_day f = f *. 86400.0

  let of_ms f = f /. 1000.0

  let of_us f = f /. 1_000_000.0

  let to_sec t = t

  let to_min t = t /. 60.0

  let to_hr t = t /. 3600.0

  let to_day t = t /. 86400.0

  let to_ms t = t *. 1000.0

  let to_us t = t *. 1_000_000.0

  let zero = 0.0

  let compare = Float.compare

  let ( + ) = ( +. )

  let ( - ) = ( -. )

  let ( / ) span divisor = span /. divisor

  let ( * ) span multiplier = span *. multiplier

  let to_string t = Printf.sprintf "%.6fs" t
end

(* Main timestamp operations *)
let diff t1 t2 = t1 -. t2

let add t span = t +. span

let sub t span = t -. span

let ( + ) = add

let ( - ) = sub

(* Aliases to match Time_ns interface *)
let now = now

let epoch = 0.0

(* Comparison functions *)
let equal = Float.equal

let ( = ) = equal

let ( <> ) t1 t2 = not (equal t1 t2)

let ( < ) = Float.( < )

let ( <= ) = Float.( <= )

let ( > ) = Float.( > )

let ( >= ) = Float.( >= )

(* Min/max *)
let min = Float.min

let max = Float.max

(* Useful constants *)
module Span_constants = struct
  let nanosecond = 1e-9

  let microsecond = 1e-6

  let millisecond = 1e-3

  let second = 1.0

  let minute = 60.0

  let hour = 3600.0

  let day = 86400.0
end
