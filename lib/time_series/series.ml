type t = {
  symbol : string;
  timestamps : (int64, Bigarray.int64_elt, Bigarray.c_layout) Bigarray.Array1.t;
  columns : (string * (float, Bigarray.float64_elt, Bigarray.c_layout) Bigarray.Array1.t) array;
  validity : (int, Bigarray.int8_unsigned_elt, Bigarray.c_layout) Bigarray.Array1.t;
}

let length t = Bigarray.Array1.dim t.timestamps

let column t ~name =
  Array.find_map (fun (n, col) -> if String.equal n name then Some col else None) t.columns


let is_valid t i = Bigarray.Array1.unsafe_get t.validity i <> 0

let of_bars ~symbol bars =
  let n = Array.length bars in
  let ts = Bigarray.Array1.create Bigarray.int64 Bigarray.c_layout n in
  let mk () = Bigarray.Array1.create Bigarray.float64 Bigarray.c_layout n in
  let o = mk () in
  let h = mk () in
  let l = mk () in
  let c = mk () in
  let v = mk () in
  let validity = Bigarray.Array1.create Bigarray.int8_unsigned Bigarray.c_layout n in
    for i = 0 to n - 1 do
      let b = bars.(i) in
        Bigarray.Array1.unsafe_set ts i b.Bar.open_ts ;
        Bigarray.Array1.unsafe_set o i b.open_ ;
        Bigarray.Array1.unsafe_set h i b.high ;
        Bigarray.Array1.unsafe_set l i b.low ;
        Bigarray.Array1.unsafe_set c i b.close ;
        Bigarray.Array1.unsafe_set v i b.volume ;
        Bigarray.Array1.unsafe_set validity i 1
    done ;
    {
      symbol;
      timestamps = ts;
      columns = [| ("open", o); ("high", h); ("low", l); ("close", c); ("volume", v) |];
      validity;
    }
