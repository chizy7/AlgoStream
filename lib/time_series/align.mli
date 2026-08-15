(** Multi-symbol time-grid alignment.

    Given N input series at potentially-different timestamps, snap them all onto a common timestamp
    grid (either an explicit array of grid points or a uniform interval). Output is a per-symbol
    [Series.t] each with the same length and timestamps. *)

type pad_policy =
  | Pad_nan
  | Drop
  | Skip_until_all_present

(** [align_to_grid ~grid ~pad ~gap_fill series_list] returns a list of aligned series — same
    timestamps, same length. Each input series is snapped to the grid (last-known value at or before
    each grid timestamp); rows where no value is known follow [pad]; remaining gaps follow
    [gap_fill]. *)
val align_to_grid :
  grid:(int64, Bigarray.int64_elt, Bigarray.c_layout) Bigarray.Array1.t ->
  pad:pad_policy ->
  gap_fill:Interpolate.strategy ->
  Series.t list ->
  Series.t list

(** Build a uniform grid spanning [start_ns..end_ns] inclusive at [step_ns]. *)
val uniform_grid :
  start_ns:int64 ->
  end_ns:int64 ->
  step_ns:int64 ->
  (int64, Bigarray.int64_elt, Bigarray.c_layout) Bigarray.Array1.t
