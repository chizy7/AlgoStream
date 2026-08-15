type outcome =
  | Allowed
  | Denied of string
  | Failed of string

let outcome_to_string = function
  | Allowed -> "allowed"
  | Denied m -> "denied:" ^ m
  | Failed m -> "failed:" ^ m


type t = {
  seq : int64;
  ts_ns : int64;
  kid : string;
  label : string;
  scopes : string;
  peer : string;
  meth : string;
  path : string;
  route : string;
  params : (string * string) list;
  body_sha256 : string;
  body_excerpt : string;
  outcome : outcome;
  status : int;
}

let excerpt_bytes = 256

let sha256_hex s = Digestif.SHA256.to_hex (Digestif.SHA256.digest_string s)

let make ~ts_ns ~kid ~label ~scopes ~peer ~meth ~path ~route ~params ~body ~outcome ~status =
  {
    seq = 0L;
    ts_ns;
    kid;
    label;
    scopes;
    peer;
    meth;
    path;
    route;
    params = List.sort (fun (a, _) (b, _) -> String.compare a b) params;
    body_sha256 = sha256_hex body;
    body_excerpt =
      (if String.length body <= excerpt_bytes then body else String.sub body 0 excerpt_bytes);
    outcome;
    status;
  }


(* ───────────────────────── canonical encoding ───────────────────────── *)

let be32 b n =
  Buffer.add_char b (Char.chr ((n lsr 24) land 0xff)) ;
  Buffer.add_char b (Char.chr ((n lsr 16) land 0xff)) ;
  Buffer.add_char b (Char.chr ((n lsr 8) land 0xff)) ;
  Buffer.add_char b (Char.chr (n land 0xff))


let be64 b (n : int64) =
  for i = 7 downto 0 do
    Buffer.add_char b
      (Char.chr (Int64.to_int (Int64.logand (Int64.shift_right_logical n (i * 8)) 0xFFL)))
  done


(* Length-prefixed. Without this, field boundaries can be moved without changing the digest. *)
let lp b s =
  be32 b (String.length s) ;
  Buffer.add_string b s


let outcome_tag = function Allowed -> 0 | Denied _ -> 1 | Failed _ -> 2

let outcome_detail = function Allowed -> "" | Denied m | Failed m -> m

let canonical t =
  let b = Buffer.create 512 in
    be64 b t.seq ;
    be64 b t.ts_ns ;
    lp b t.kid ;
    lp b t.label ;
    lp b t.scopes ;
    lp b t.peer ;
    lp b t.meth ;
    lp b t.path ;
    lp b t.route ;
    be32 b (List.length t.params) ;
    List.iter
      (fun (k, v) ->
        lp b k ;
        lp b v)
      t.params ;
    lp b t.body_sha256 ;
    lp b t.body_excerpt ;
    Buffer.add_char b (Char.chr (outcome_tag t.outcome)) ;
    lp b (outcome_detail t.outcome) ;
    be32 b t.status ;
    Buffer.contents b


let to_line t =
  Printf.sprintf "%6Ld  %s  %-10s %-7s %-3d %-40s %s%s" t.seq
    (let tm = Unix.gmtime (Int64.to_float t.ts_ns /. 1e9) in
       Printf.sprintf "%04d-%02d-%02dT%02d:%02d:%02dZ" (tm.Unix.tm_year + 1900) (tm.Unix.tm_mon + 1)
         tm.Unix.tm_mday tm.Unix.tm_hour tm.Unix.tm_min tm.Unix.tm_sec)
    t.kid t.meth t.status t.path (outcome_to_string t.outcome)
    (if String.equal t.body_excerpt "" then "" else "  body=" ^ String.escaped t.body_excerpt)
