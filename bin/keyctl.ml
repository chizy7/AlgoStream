(* algostream-keyctl — manage the dashboard API keystore.

   The secret is printed exactly once, at creation, and never stored: the keystore holds only a
   SHA-256 digest. A lost key is regenerated, not recovered. Everything else here — list, expire,
   revoke, prune — operates on metadata and never has the secret to leak. *)

module Auth = Algostream_infrastructure_auth
module Scope = Auth.Scope
module Keystore = Auth.Keystore

let default_path () =
  let base =
    match Sys.getenv_opt "XDG_CONFIG_HOME" with
    | Some d when d <> "" -> d
    | _ -> Filename.concat (Option.value ~default:"." (Sys.getenv_opt "HOME")) ".config" in
    Filename.concat (Filename.concat base "algostream") "keys.json"


let usage () =
  print_string
    {|algostream-keyctl — manage the dashboard API keystore

  algostream-keyctl add    --label TEXT [--scopes read,control] [--expires-in DURATION]
  algostream-keyctl list
  algostream-keyctl expire --kid KID --in DURATION
  algostream-keyctl revoke --kid KID
  algostream-keyctl prune  [--older-than DURATION]

  --file PATH    keystore location (default $XDG_CONFIG_HOME/algostream/keys.json)

DURATION is a number followed by s, m, h or d — for example 24h or 30d.

Rotation is an overlap window: add the new key, then `expire --kid OLD --in 24h`. Both authenticate
until the clock passes it, so there is no moment where neither works. Audit records keep whichever
key id was actually used.

The key itself is shown once, when it is created. Only its hash is stored.
|} ;
  exit 0


let now_ns () = Int64.of_float (Unix.gettimeofday () *. 1e9)

let parse_duration s =
  let n = String.length s in
    if n < 2 then None
    else
      match (float_of_string_opt (String.sub s 0 (n - 1)), s.[n - 1]) with
      | Some v, 's' -> Some (Int64.of_float (v *. 1e9))
      | Some v, 'm' -> Some (Int64.of_float (v *. 60e9))
      | Some v, 'h' -> Some (Int64.of_float (v *. 3600e9))
      | Some v, 'd' -> Some (Int64.of_float (v *. 86400e9))
      | _ -> None


let fmt_ns ns =
  let tm = Unix.gmtime (Int64.to_float ns /. 1e9) in
    Printf.sprintf "%04d-%02d-%02dT%02d:%02dZ" (tm.Unix.tm_year + 1900) (tm.Unix.tm_mon + 1)
      tm.Unix.tm_mday tm.Unix.tm_hour tm.Unix.tm_min


let die fmt =
  Printf.ksprintf
    (fun s ->
      prerr_endline ("algostream-keyctl: " ^ s) ;
      exit 2)
    fmt


let load_or_empty path =
  if Sys.file_exists path then
    match Keystore.load path with Ok ks -> Keystore.records ks | Error e -> die "%s" e
  else []


let ensure_dir path =
  let dir = Filename.dirname path in
    if not (Sys.file_exists dir) then
      let rec go d =
        if not (Sys.file_exists d) then (
          go (Filename.dirname d) ;
          try Unix.mkdir d 0o700 with Unix.Unix_error (Unix.EEXIST, _, _) -> ()) in
        go dir


let save path recs = match Keystore.save path recs with Ok () -> () | Error e -> die "%s" e

let cmd_add ~path ~label ~scopes ~expires_in =
  if String.equal label "" then die "add needs --label" ;
  let scopes =
    match scopes with
    | [] -> [ Scope.Read ]
    | l -> List.map (fun s -> match Scope.of_string s with Ok x -> x | Error e -> die "%s" e) l
  in
  let recs = load_or_empty path in
  let wire, parsed = Auth.Api_key.generate () in
  let now = now_ns () in
  let r =
    Keystore.make_record ~kid:parsed.Auth.Api_key.kid ~label ~scopes:(Scope.Set.of_list scopes)
      ~secret:parsed.Auth.Api_key.secret ~now_ns:now
      ~expires_ns:(Option.map (fun d -> Int64.add now d) expires_in) in
    ensure_dir path ;
    save path (recs @ [ r ]) ;
    Printf.printf "kid:    %s\nlabel:  %s\nscopes: %s\n\n" r.Keystore.kid r.Keystore.label
      (Scope.Set.to_string r.Keystore.scopes) ;
    Printf.printf "key:    %s\n\n" wire ;
    print_endline "This is the only time the key is shown. Store it now; only its hash is kept."


let cmd_list ~path =
  let recs = load_or_empty path in
  let now = now_ns () in
    if recs = [] then print_endline "no keys"
    else (
      Printf.printf "%-10s %-24s %-14s %-18s %s\n" "KID" "LABEL" "SCOPES" "EXPIRES" "STATE" ;
      List.iter
        (fun (r : Keystore.record) ->
          let state =
            match r.Keystore.revoked_ns with
            | Some t -> "revoked " ^ fmt_ns t
            | None ->
              (match r.Keystore.expires_ns with
              | Some e when Int64.compare now e >= 0 -> "expired"
              | _ -> "active") in
            Printf.printf "%-10s %-24s %-14s %-18s %s\n" r.Keystore.kid r.Keystore.label
              (Scope.Set.to_string r.Keystore.scopes)
              (match r.Keystore.expires_ns with None -> "never" | Some e -> fmt_ns e)
              state)
        recs)


let update_one ~path ~kid ~f =
  let recs = load_or_empty path in
    if not (List.exists (fun (r : Keystore.record) -> String.equal r.Keystore.kid kid) recs) then
      die "no key with id %s" kid ;
    save path
      (List.map
         (fun (r : Keystore.record) -> if String.equal r.Keystore.kid kid then f r else r)
         recs)


let cmd_expire ~path ~kid ~in_ =
  match in_ with
  | None -> die "expire needs --in DURATION"
  | Some d ->
    let at = Int64.add (now_ns ()) d in
      update_one ~path ~kid ~f:(fun r -> { r with Keystore.expires_ns = Some at }) ;
      Printf.printf "%s expires %s\n" kid (fmt_ns at)


let cmd_revoke ~path ~kid =
  let now = now_ns () in
    update_one ~path ~kid ~f:(fun r -> { r with Keystore.revoked_ns = Some now }) ;
    Printf.printf "%s revoked\n" kid ;
    (* The daemon re-stats the keystore at most once a second, so say so rather than let an operator
       wonder whether it took. Open event streams are dropped on the next push tick. *)
    print_endline "takes effect in the running daemon within one second"


let cmd_prune ~path ~older_than =
  let cutoff =
    Int64.sub (now_ns ()) (Option.value ~default:(Int64.mul 30L 86_400_000_000_000L) older_than)
  in
  let recs = load_or_empty path in
  let keep, drop =
    List.partition
      (fun (r : Keystore.record) ->
        match (r.Keystore.revoked_ns, r.Keystore.expires_ns) with
        | Some t, _ | None, Some t -> Int64.compare t cutoff >= 0
        | None, None -> true)
      recs in
    save path keep ;
    Printf.printf "pruned %d, kept %d\n" (List.length drop) (List.length keep)


let () =
  let n = Array.length Sys.argv in
    if n < 2 then usage () ;
    let path = ref (default_path ()) in
    let label = ref "" in
    let scopes = ref [] in
    let kid = ref "" in
    let dur = ref None in
    let need i what = if i + 1 >= n then die "--%s needs a value" what else Sys.argv.(i + 1) in
    let cmd = Sys.argv.(1) in
    let i = ref 2 in
      while !i < n do
        (match Sys.argv.(!i) with
        | "--file" ->
          path := need !i "file" ;
          incr i
        | "--label" ->
          label := need !i "label" ;
          incr i
        | "--scopes" ->
          scopes :=
            need !i "scopes" |> String.split_on_char ',' |> List.map String.trim
            |> List.filter (fun s -> s <> "") ;
          incr i
        | "--kid" ->
          kid := need !i "kid" ;
          incr i
        | "--in" | "--expires-in" | "--older-than" ->
          (match parse_duration (need !i "duration") with
          | Some d -> dur := Some d
          | None -> die "duration must look like 30d, 24h, 15m or 90s") ;
          incr i
        | "-h" | "--help" -> usage ()
        | other -> die "unknown argument %s" other) ;
        incr i
      done ;
      match cmd with
      | "add" -> cmd_add ~path:!path ~label:!label ~scopes:!scopes ~expires_in:!dur
      | "list" -> cmd_list ~path:!path
      | "expire" ->
        if !kid = "" then die "expire needs --kid" ;
        cmd_expire ~path:!path ~kid:!kid ~in_:!dur
      | "revoke" ->
        if !kid = "" then die "revoke needs --kid" ;
        cmd_revoke ~path:!path ~kid:!kid
      | "prune" -> cmd_prune ~path:!path ~older_than:!dur
      | "-h" | "--help" -> usage ()
      | other -> die "unknown command %s (try --help)" other
