let capacity = 64

let ttl_ns = 30_000_000_000L

type entry = {
  hash : string;  (** digest of the ticket, never the ticket itself *)
  kid : string;
  label : string;
  scopes : Scope.Set.t;
  minted_ns : int64;
}

(* Oldest first, so eviction and expiry sweeping both work from the front. The list is at most
   [capacity] long and touched a handful of times a day, so a list beats anything cleverer. *)
type t = { mutable entries : entry list }

let create () = { entries = [] }

let hex_encode s =
  String.concat ""
    (List.map (fun c -> Printf.sprintf "%02x" (Char.code c)) (List.of_seq (String.to_seq s)))


let live ~now_ns e = Int64.compare (Int64.sub now_ns e.minted_ns) ttl_ns < 0

let sweep t ~now_ns = t.entries <- List.filter (live ~now_ns) t.entries

let mint t ~now_ns ~kid ~scopes =
  sweep t ~now_ns ;
  let ticket = hex_encode (Mirage_crypto_rng_unix.getrandom 16) in
  let entry = { hash = Api_key.hash ticket; kid; label = kid; scopes; minted_ns = now_ns } in
  let kept =
    (* Drop the oldest when full. A client that mints without connecting evicts only its own
       backlog; it cannot push the table past [capacity]. *)
    if List.length t.entries >= capacity then List.tl t.entries else t.entries in
    t.entries <- kept @ [ entry ] ;
    ticket


let redeem t ~now_ns ~ticket =
  sweep t ~now_ns ;
  let rec take acc = function
    | [] -> None
    | e :: rest ->
      if Api_key.verify ~secret:ticket ~stored:e.hash then (
        (* Single use: remove it before returning, so a concurrent second redemption finds
           nothing. *)
        t.entries <- List.rev_append acc rest ;
        Some (Principal.Key { kid = e.kid; label = e.label; scopes = e.scopes }))
      else take (e :: acc) rest in
    take [] t.entries


let outstanding t = List.length t.entries
