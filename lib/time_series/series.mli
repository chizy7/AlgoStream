(** A timestamped multi-column series.

    Each row at index [i] has timestamp [timestamps.{i}] and value [columns.(j).{i}] for column [j].
    The optional [validity.{i}] (int8 0/1) flags whether that row is real (1) or a fill /
    placeholder (0). Used by alignment + interpolation. *)

type t = {
  symbol : string;
  timestamps : (int64, Bigarray.int64_elt, Bigarray.c_layout) Bigarray.Array1.t;
  columns : (string * (float, Bigarray.float64_elt, Bigarray.c_layout) Bigarray.Array1.t) array;
  validity : (int, Bigarray.int8_unsigned_elt, Bigarray.c_layout) Bigarray.Array1.t;
}

val length : t -> int

val column :
  t -> name:string -> (float, Bigarray.float64_elt, Bigarray.c_layout) Bigarray.Array1.t option

val is_valid : t -> int -> bool

(** Build a series from a list of [Bar.t]. Columns are open/high/low/close/volume. *)
val of_bars : symbol:string -> Bar.t array -> t
