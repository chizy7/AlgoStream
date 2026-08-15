let version = 1

type record = {
  kid : string;
  label : string;
  scopes : Scope.Set.t;
  hash : string;
  created_ns : int64;
  expires_ns : int64 option;
  revoked_ns : int64 option;
}

type t = {
  path : string;
  mutable recs : record list;
  (* Cache validity: [stat]ed at most once per [reload_interval_ns], reloaded only when mtime or
     size actually moved. *)
  mutable last_stat_ns : int64;
  mutable last_mtime : float;
  mutable last_size : int;
}

type failure =
  | Malformed of string
  | Unknown_key
  | Expired
  | Revoked
  | Insufficient_scope of Scope.t

let failure_to_string = function
  | Malformed m -> "malformed credential: " ^ m
  | Unknown_key -> "unknown key"
  | Expired -> "key expired"
  | Revoked -> "key revoked"
  | Insufficient_scope s -> "requires the " ^ Scope.to_string s ^ " scope"


let reload_interval_ns = 1_000_000_000L

let path t = t.path

let records t = t.recs

let empty path = { path; recs = []; last_stat_ns = 0L; last_mtime = 0.0; last_size = -1 }

let make_record ~kid ~label ~scopes ~secret ~now_ns ~expires_ns =
  {
    kid;
    label;
    scopes;
    hash = Api_key.hash secret;
    created_ns = now_ns;
    expires_ns;
    revoked_ns = None;
  }


(* ───────────────────────── json ───────────────────────── *)

let scopes_to_json s = `List (List.map (fun x -> `String (Scope.to_string x)) (Scope.Set.to_list s))

let int64_opt_to_json = function None -> `Null | Some v -> `Intlit (Int64.to_string v)

let record_to_json r =
  `Assoc
    [
      ("kid", `String r.kid);
      ("label", `String r.label);
      ("scopes", scopes_to_json r.scopes);
      ("hash", `String r.hash);
      ("created_ns", `Intlit (Int64.to_string r.created_ns));
      ("expires_ns", int64_opt_to_json r.expires_ns);
      ("revoked_ns", int64_opt_to_json r.revoked_ns);
    ]


exception Bad of string

let bad fmt = Printf.ksprintf (fun s -> raise (Bad s)) fmt

let member k = function
  | `Assoc kvs -> (match List.assoc_opt k kvs with Some v -> v | None -> `Null)
  | _ -> `Null


let to_string_field name j =
  match j with
  | `String s -> s
  | `Null -> bad "missing %S" name
  | _ -> bad "%S must be a string" name


let to_int64_field name j =
  match j with
  | `Int i -> Int64.of_int i
  | `Intlit s -> (try Int64.of_string s with _ -> bad "%S is not an integer" name)
  | `Null -> bad "missing %S" name
  | _ -> bad "%S must be an integer" name


let to_int64_opt_field name j =
  match j with `Null -> None | other -> Some (to_int64_field name other)


let record_of_json j =
  let scopes =
    match member "scopes" j with
    | `List l ->
      Scope.Set.of_list
        (List.map
           (fun s ->
             match s with
             | `String s -> (match Scope.of_string s with Ok x -> x | Error m -> bad "%s" m)
             | _ -> bad "each scope must be a string")
           l)
    | `Null -> bad "missing \"scopes\""
    | _ -> bad "\"scopes\" must be a list" in
  let kid = to_string_field "kid" (member "kid" j) in
    if String.length kid <> Api_key.kid_chars then
      bad "key id %S must be %d hex characters" kid Api_key.kid_chars ;
    {
      kid;
      label = to_string_field "label" (member "label" j);
      scopes;
      hash = to_string_field "hash" (member "hash" j);
      created_ns = to_int64_field "created_ns" (member "created_ns" j);
      expires_ns = to_int64_opt_field "expires_ns" (member "expires_ns" j);
      revoked_ns = to_int64_opt_field "revoked_ns" (member "revoked_ns" j);
    }


let parse_json json =
  match member "version" json with
  | `Int v when v = version ->
    (match member "keys" json with
    | `List l ->
      let recs = List.map record_of_json l in
      let seen = Hashtbl.create 8 in
        List.iter
          (fun r ->
            if Hashtbl.mem seen r.kid then bad "duplicate key id %S" r.kid ;
            Hashtbl.add seen r.kid ())
          recs ;
        recs
    | _ -> bad "\"keys\" must be a list")
  | `Int v -> bad "keystore version %d, expected %d" v version
  | _ -> bad "missing \"version\""


(* ───────────────────────── permissions ───────────────────────── *)

(* Refusals, not warnings. Each returns a message naming the path, because the reader of this string
   is an operator working out why a daemon will not start.

   The rule is "no principal other than this process can read the file", not "the mode is 0600".
   Those coincide on a laptop and diverge in a container, and an earlier version of this check
   enforced the literal mode — which made the keystore impossible to mount in Kubernetes at all:

   - A Secret volume is owned by {b root}, not by the container's user, so the uid equality check
   could never pass however the pod was written. - Setting [fsGroup] (which the audit PVC needs, so
   that a non-root user can write to it) makes the kubelet add group-read to every volume in the
   pod, so [defaultMode: 0400] arrives as 0440 and the [0o077] mask rejected it.

   Neither is an exposure: the group in question is the pod's own [fsGroup], and root owning a
   read-only mount is how Kubernetes projects every secret. What would be an exposure is world
   access, or a group that is not ours — both still refused. This was found by applying k8s/ to a
   real cluster; no amount of manifest linting reaches it. *)
let check_permissions path =
  match Unix.stat path with
  | exception Unix.Unix_error (e, _, _) ->
    Error (Printf.sprintf "cannot stat %s: %s" path (Unix.error_message e))
  | st ->
    let perm = st.Unix.st_perm in
      if perm land 0o007 <> 0 then
        Error
          (Printf.sprintf "%s is mode %04o — it is readable by other users (chmod 600 %s)" path perm
             path)
      else if perm land 0o070 <> 0 && st.Unix.st_gid <> Unix.getegid () then
        Error
          (Printf.sprintf
             "%s is mode %04o and owned by group %d, which is not this process's group (%d) — \
              members of that group can read it (chmod 600 %s)"
             path perm st.Unix.st_gid (Unix.getegid ()) path)
      else if st.Unix.st_uid <> Unix.geteuid () && st.Unix.st_uid <> 0 then
        Error
          (Printf.sprintf "%s is owned by uid %d, neither this process (uid %d) nor root" path
             st.Unix.st_uid (Unix.geteuid ()))
      else if st.Unix.st_uid = 0 && st.Unix.st_uid <> Unix.geteuid () && perm land 0o022 <> 0 then
        (* A root-owned file we do not own is only acceptable read-only; if it is group- or
           world-writable, something other than root can replace the keys under us. *)
        Error
          (Printf.sprintf
             "%s is root-owned and mode %04o — it must not be writable by group or others" path perm)
      else
        let dir = Filename.dirname path in
          (match Unix.stat dir with
          | exception Unix.Unix_error (e, _, _) ->
            Error (Printf.sprintf "cannot stat %s: %s" dir (Unix.error_message e))
          | dst ->
            (* The question is whether the file can be *replaced*, and the mode bits alone do not
               answer it. Kubernetes projects a Secret onto a tmpfs whose mount point reads as
               world-writable, but mounts it read-only, so nothing can write there whatever the bits
               say — and refusing on the bits alone stopped the daemon from ever starting in a pod.
               [access W_OK] tests the property directly and returns false on a read-only mount. *)
            let writable =
              match Unix.access dir [ Unix.W_OK ] with
              | () -> true
              | exception Unix.Unix_error _ -> false in
              if dst.Unix.st_perm land 0o002 <> 0 && writable then
                Error
                  (Printf.sprintf "%s is world-writable, so %s can be replaced by anyone" dir path)
              else Ok st)


let read_file path =
  let ic = open_in_bin path in
    Fun.protect
      ~finally:(fun () -> close_in_noerr ic)
      (fun () -> really_input_string ic (in_channel_length ic))


let load path =
  match check_permissions path with
  | Error e -> Error e
  | Ok st ->
    (try
       let recs = parse_json (Yojson.Safe.from_string (read_file path)) in
         Ok
           {
             path;
             recs;
             last_stat_ns = 0L;
             last_mtime = st.Unix.st_mtime;
             last_size = st.Unix.st_size;
           }
     with
    | Bad m -> Error (Printf.sprintf "%s: %s" path m)
    | Yojson.Json_error m -> Error (Printf.sprintf "%s: invalid json: %s" path m)
    | Sys_error m -> Error m)


let save path recs =
  let json = `Assoc [ ("version", `Int version); ("keys", `List (List.map record_to_json recs)) ] in
  let body = Yojson.Safe.pretty_to_string json ^ "\n" in
  (* Same directory, so the rename is atomic rather than a cross-device copy. *)
  let tmp = Filename.concat (Filename.dirname path) (Filename.basename path ^ ".tmp") in
    try
      (try Unix.unlink tmp with Unix.Unix_error (Unix.ENOENT, _, _) -> ()) ;
      let fd = Unix.openfile tmp [ Unix.O_WRONLY; Unix.O_CREAT; Unix.O_EXCL ] 0o600 in
        Fun.protect
          ~finally:(fun () -> try Unix.close fd with _ -> ())
          (fun () ->
            let b = Bytes.of_string body in
            let n = Unix.write fd b 0 (Bytes.length b) in
              if n <> Bytes.length b then failwith "short write" ;
              Unix.fsync fd) ;
        Unix.rename tmp path ;
        Ok ()
    with
    | Unix.Unix_error (e, fn, _) ->
      Error (Printf.sprintf "%s: %s: %s" path fn (Unix.error_message e))
    | Failure m -> Error (Printf.sprintf "%s: %s" path m)


(* ───────────────────────── reload ───────────────────────── *)

let maybe_reload t ~now_ns =
  if Int64.sub now_ns t.last_stat_ns < reload_interval_ns then ()
  else (
    t.last_stat_ns <- now_ns ;
    match Unix.stat t.path with
    | exception Unix.Unix_error _ -> ()
    | st ->
      if st.Unix.st_mtime <> t.last_mtime || st.Unix.st_size <> t.last_size then (
        match load t.path with
        | Ok fresh ->
          t.recs <- fresh.recs ;
          t.last_mtime <- st.Unix.st_mtime ;
          t.last_size <- st.Unix.st_size
        | Error m ->
          (* Deliberately keep serving the last good store. Locking the operator out of a running
             system over a hand-edit is worse than a stale policy; record the mtime anyway so this
             is logged once rather than every second. *)
          t.last_mtime <- st.Unix.st_mtime ;
          t.last_size <- st.Unix.st_size ;
          Logs.err (fun m' -> m' "keystore reload failed, keeping the previous keys: %s" m)))


let find t kid = List.find_opt (fun r -> String.equal r.kid kid) t.recs

let live ~now_ns r =
  match r.revoked_ns with
  | Some _ -> false
  | None -> (match r.expires_ns with Some e -> Int64.compare now_ns e < 0 | None -> true)


let is_live t ~now_ns ~kid =
  maybe_reload t ~now_ns ;
  match find t kid with None -> false | Some r -> live ~now_ns r


let authenticate t ~now_ns ~credential ~required =
  maybe_reload t ~now_ns ;
  match Api_key.parse credential with
  | Error m -> Error (Malformed m)
  | Ok { kid; secret } ->
    (match find t kid with
    | None ->
      (* Burn the same work as a real comparison so timing does not distinguish an unknown key id
         from a wrong secret. *)
      ignore (Api_key.verify ~secret ~stored:Api_key.dummy_hash) ;
      Error Unknown_key
    | Some r ->
      if not (Api_key.verify ~secret ~stored:r.hash) then Error Unknown_key
      else if r.revoked_ns <> None then Error Revoked
      else if not (live ~now_ns r) then Error Expired
      else if not (Scope.satisfies ~granted:r.scopes ~required) then
        Error (Insufficient_scope required)
      else Ok (Principal.Key { kid = r.kid; label = r.label; scopes = r.scopes }))
