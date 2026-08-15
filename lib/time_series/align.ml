type pad_policy =
  | Pad_nan
  | Drop
  | Skip_until_all_present

let uniform_grid ~start_ns ~end_ns ~step_ns =
  if Int64.compare step_ns 0L <= 0 then invalid_arg "uniform_grid: step_ns must be > 0" ;
  let span = Int64.sub end_ns start_ns in
  let n = Int64.add (Int64.div span step_ns) 1L |> Int64.to_int in
  let n = max 0 n in
  let g = Bigarray.Array1.create Bigarray.int64 Bigarray.c_layout n in
    for i = 0 to n - 1 do
      Bigarray.Array1.unsafe_set g i (Int64.add start_ns (Int64.mul (Int64.of_int i) step_ns))
    done ;
    g


(* Find the last index in src.timestamps with ts <= target. Returns -1 if none. *)
let last_at_or_before (ts : (int64, Bigarray.int64_elt, Bigarray.c_layout) Bigarray.Array1.t) target
    =
  let n = Bigarray.Array1.dim ts in
  let rec bin lo hi =
    if lo > hi then hi
    else
      let mid = (lo + hi) / 2 in
      let v = Bigarray.Array1.unsafe_get ts mid in
        if Int64.compare v target <= 0 then bin (mid + 1) hi else bin lo (mid - 1) in
  let n = n - 1 in
    bin 0 n


let snap_one_series ~grid ~pad src =
  let g_n = Bigarray.Array1.dim grid in
  let validity = Bigarray.Array1.create Bigarray.int8_unsigned Bigarray.c_layout g_n in
    for i = 0 to g_n - 1 do
      Bigarray.Array1.unsafe_set validity i 0
    done ;
    let mk () = Bigarray.Array1.create Bigarray.float64 Bigarray.c_layout g_n in
    let columns =
      Array.map
        (fun (name, src_col) ->
          let dst = mk () in
            for i = 0 to g_n - 1 do
              let target = Bigarray.Array1.unsafe_get grid i in
              let idx = last_at_or_before src.Series.timestamps target in
                if idx >= 0 && Series.is_valid src idx then (
                  Bigarray.Array1.unsafe_set dst i (Bigarray.Array1.unsafe_get src_col idx) ;
                  (* validity is across-column; OR-in across all columns happens below *)
                  Bigarray.Array1.unsafe_set validity i 1)
                else (
                  (match pad with
                  | Pad_nan -> Bigarray.Array1.unsafe_set dst i Float.nan
                  | _ -> Bigarray.Array1.unsafe_set dst i 0.0) ;
                  ignore (Bigarray.Array1.unsafe_get validity i))
            done ;
            (name, dst))
        src.columns in
      { src with timestamps = grid; columns; validity }


let align_to_grid ~grid ~pad ~gap_fill series_list =
  let snapped = List.map (snap_one_series ~grid ~pad) series_list in
    (match pad with
    | Skip_until_all_present | Drop ->
      (* Find the first index where every series has a real value, and clip everything before. *)
      let first_all =
        let g_n = Bigarray.Array1.dim grid in
        let rec scan i =
          if i >= g_n then g_n
          else if List.for_all (fun s -> Series.is_valid s i) snapped then i
          else scan (i + 1) in
          scan 0 in
        if first_all > 0 then
          List.iter
            (fun s ->
              for i = 0 to first_all - 1 do
                Bigarray.Array1.unsafe_set s.Series.validity i 0
              done)
            snapped
    | Pad_nan -> ()) ;
    List.iter
      (fun s ->
        Array.iter
          (fun (_n, col) ->
            ignore (Interpolate.fill_in_place ~validity:s.Series.validity ~col ~strategy:gap_fill))
          s.columns)
      snapped ;
    snapped
