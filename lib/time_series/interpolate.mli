(** Gap-filling for timestamped series.

    Three strategies:
    - [Forward_fill]: use the last known value to fill rows where validity = 0.
    - [Linear]: linearly interpolate between the surrounding valid rows.
    - [Leave_nan]: write [Float.nan] into the column at invalid rows; leave validity untouched.

    Interpolation across a feed-down gap is forbidden — callers can pre-mark such ranges by setting
    validity to [2] (gap-protected) and the interpolators will leave them alone. *)

type strategy =
  | Forward_fill
  | Linear
  | Leave_nan

(** Apply [strategy] to a single column in-place. Returns the number of cells filled. *)
val fill_in_place :
  validity:(int, Bigarray.int8_unsigned_elt, Bigarray.c_layout) Bigarray.Array1.t ->
  col:(float, Bigarray.float64_elt, Bigarray.c_layout) Bigarray.Array1.t ->
  strategy:strategy ->
  int
