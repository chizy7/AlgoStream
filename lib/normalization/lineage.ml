type t = string list

let max_length = 64

let valid_segment s =
  String.length s > 0
  && String.for_all (fun c -> (c >= 'a' && c <= 'z') || (c >= '0' && c <= '9') || c = '_') s


let is_valid s =
  if String.length s > max_length || String.length s = 0 then false
  else
    let parts = String.split_on_char '/' s in
      List.for_all valid_segment parts


let of_source s = if String.length s = 0 then [] else String.split_on_char '/' s

let to_source parts = String.concat "/" parts

let push parent child =
  if not (valid_segment child) then None
  else
    let candidate =
      if String.length parent = 0 then child else Printf.sprintf "%s/%s" parent child in
      if is_valid candidate then Some candidate else None
