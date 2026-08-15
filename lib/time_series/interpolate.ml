type strategy =
  | Forward_fill
  | Linear
  | Leave_nan

let valid_at validity i = Bigarray.Array1.unsafe_get validity i = 1

let fill_in_place ~validity ~col ~strategy =
  let n = Bigarray.Array1.dim validity in
  let filled = ref 0 in
    match strategy with
    | Leave_nan ->
      for i = 0 to n - 1 do
        if not (valid_at validity i) then (
          Bigarray.Array1.unsafe_set col i Float.nan ;
          incr filled)
      done ;
      !filled
    | Forward_fill ->
      let last = ref None in
        for i = 0 to n - 1 do
          if valid_at validity i then last := Some (Bigarray.Array1.unsafe_get col i)
          else
            match !last with
            | Some v ->
              Bigarray.Array1.unsafe_set col i v ;
              (* Mark as filled (validity 1) so downstream is_valid treats it as real-ish. Callers
                 who need to distinguish real-vs-filled should snapshot validity first. *)
              Bigarray.Array1.unsafe_set validity i 1 ;
              incr filled
            | None -> Bigarray.Array1.unsafe_set col i Float.nan
        done ;
        !filled
    | Linear ->
      (* Walk the array; for each invalid run [a..b-1] surrounded by valid indices [a-1] and [b],
         interpolate. Leading / trailing invalid runs are left as NaN. *)
      let i = ref 0 in
        while !i < n do
          if valid_at validity !i then incr i
          else
            let a = !i in
              while !i < n && not (valid_at validity !i) do
                incr i
              done ;
              let b = !i in
                if a > 0 && b < n then
                  let v_a = Bigarray.Array1.unsafe_get col (a - 1) in
                  let v_b = Bigarray.Array1.unsafe_get col b in
                  let span = float_of_int (b - a + 1) in
                    for j = a to b - 1 do
                      let t = float_of_int (j - a + 1) /. span in
                      let v = v_a +. (t *. (v_b -. v_a)) in
                        Bigarray.Array1.unsafe_set col j v ;
                        Bigarray.Array1.unsafe_set validity j 1 ;
                        incr filled
                    done
                else
                  for j = a to b - 1 do
                    Bigarray.Array1.unsafe_set col j Float.nan
                  done
        done ;
        !filled
