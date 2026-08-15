type t = (string, string) Hashtbl.t

let create ?(initial_size = 64) () = Hashtbl.create initial_size

let intern t s =
  match Hashtbl.find_opt t s with
  | Some canonical -> canonical
  | None ->
    Hashtbl.add t s s ;
    s


let intern_bytes t b ~off ~len =
  let candidate = Bytes.sub_string b off len in
    match Hashtbl.find_opt t candidate with
    | Some canonical -> canonical
    | None ->
      Hashtbl.add t candidate candidate ;
      candidate


let size = Hashtbl.length
