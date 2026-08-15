type value =
  | S of string
  | F of float
  | I of int
  | I64 of int64
  | B of bool

type column = {
  header : string;
  extract : unit -> value;
}

let needs_quoting s =
  let n = String.length s in
  let rec go i =
    if i >= n then false else match s.[i] with ',' | '"' | '\n' | '\r' -> true | _ -> go (i + 1)
  in
    go 0


let csv_escape s =
  if not (needs_quoting s) then s
  else
    let b = Buffer.create (String.length s + 8) in
      Buffer.add_char b '"' ;
      String.iter (fun c -> if c = '"' then Buffer.add_string b "\"\"" else Buffer.add_char b c) s ;
      Buffer.add_char b '"' ;
      Buffer.contents b


let value_to_csv = function
  | S s -> csv_escape s
  (* An empty cell rather than "nan": spreadsheets treat nan as text and it poisons a whole column's
     type inference. *)
  | F f -> if Float.is_finite f then Printf.sprintf "%.8g" f else ""
  | I i -> string_of_int i
  | I64 i -> Int64.to_string i
  | B b -> if b then "true" else "false"


let to_csv ~headers ~rows =
  let b = Buffer.create 4096 in
    Buffer.add_string b (String.concat "," (List.map csv_escape headers)) ;
    Buffer.add_char b '\n' ;
    List.iter
      (fun row ->
        Buffer.add_string b (String.concat "," (List.map value_to_csv row)) ;
        Buffer.add_char b '\n')
      rows ;
    Buffer.contents b


let json_of_value = function
  | S s -> `String s
  | F f -> if Float.is_finite f then `Float f else `Null
  | I i -> `Int i
  | I64 i -> `Intlit (Int64.to_string i)
  | B b -> `Bool b


let to_json ~headers ~rows =
  let obj_of_row row =
    (* A short row pads with null rather than raising: a truncated export is more useful than an
       exception in a reporting endpoint. *)
    let rec zip hs vs acc =
      match (hs, vs) with
      | [], _ -> List.rev acc
      | h :: ht, [] -> zip ht [] ((h, `Null) :: acc)
      | h :: ht, v :: vt -> zip ht vt ((h, json_of_value v) :: acc) in
      `Assoc (zip headers row []) in
    Yojson.Safe.to_string (`List (List.map obj_of_row rows))


type format =
  | Csv
  | Json

let format_of_string s =
  match String.lowercase_ascii s with
  | "csv" -> Ok Csv
  | "json" -> Ok Json
  | "xlsx" | "excel" -> Error "xlsx export is not implemented; CSV opens directly in Excel"
  | other -> Error (Printf.sprintf "unknown format %S (expected csv or json)" other)


let format_to_string = function Csv -> "csv" | Json -> "json"

let content_type = function
  | Csv -> "text/csv; charset=utf-8"
  | Json -> "application/json; charset=utf-8"


let render fmt ~headers ~rows =
  match fmt with Csv -> to_csv ~headers ~rows | Json -> to_json ~headers ~rows


let to_file path fmt ~headers ~rows =
  let oc = open_out path in
    Fun.protect
      ~finally:(fun () -> close_out oc)
      (fun () -> output_string oc (render fmt ~headers ~rows))
