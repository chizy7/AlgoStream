type t =
  | Public
  | Read
  | Control

let to_string = function Public -> "public" | Read -> "read" | Control -> "control"

let of_string = function
  | "read" -> Ok Read
  | "control" -> Ok Control
  | "public" ->
    Error "\"public\" is a property of a route, not a scope a key can hold; use read or control"
  | other -> Error (Printf.sprintf "unknown scope %S (expected read or control)" other)


module Set = struct
  (* Two members, so a pair of bools beats a set structure and keeps [satisfies] branch-free. *)
  type t = {
    read : bool;
    control : bool;
  }

  let empty = { read = false; control = false }

  let of_list =
    List.fold_left
      (fun acc s ->
        match s with
        | Read -> { acc with read = true }
        | Control -> { acc with control = true }
        | Public -> acc)
      empty


  let to_list t = (if t.read then [ Read ] else []) @ if t.control then [ Control ] else []

  let mem t = function
    | Read -> t.read || t.control (* control implies read *)
    | Control -> t.control
    | Public -> true


  let to_string t =
    match to_list t with [] -> "(none)" | l -> String.concat "," (List.map to_string l)
end

let satisfies ~granted ~required =
  match required with Public -> true | (Read | Control) as r -> Set.mem granted r
