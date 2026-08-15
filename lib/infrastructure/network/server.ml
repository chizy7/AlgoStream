module Lwt_host = Algostream_infrastructure_lwt_host.Lwt_host

let src = Logs.Src.create "algostream.infrastructure.network"

module Log = (val Logs.src_log src : Logs.LOG)

module Auth = Algostream_infrastructure_auth
module Scope = Auth.Scope
module Principal = Auth.Principal
module Keystore = Auth.Keystore
module Audit_record = Algostream_infrastructure_persistence.Audit_record
module Audit = Audit_record

type request = {
  path_params : (string * string) list;
  query : (string * string) list;
  body : string;
  principal : Principal.t;
}

type handler = request -> Json.t * int

type route = {
  meth : [ `GET | `POST | `PUT ];
  path : string;
  scope : Scope.t;
  handler : handler;
}

type config = {
  host : string;
  port : int;
  static_root : string option;
  push_interval_s : float;
}

let default_config = { host = "127.0.0.1"; port = 8080; static_root = None; push_interval_s = 0.25 }

(* A connected event-stream client. [kid] is carried so the push loop can drop the stream when the
   key that opened it is revoked; a long-lived connection must not outlive its credential. *)
type client = {
  id : int;
  stream : string Lwt_stream.t;
  push : string option -> unit;
  kid : string;
}

type t = {
  cfg : config;
  routes : route list;
  snapshot : unit -> Json.t;
  clients : client list Atomic.t;
  next_client_id : int Atomic.t;
  auth : Auth.Keystore.t option;
  tickets : Auth.Ticket.t;
  limiter : Auth.Rate_limit.t;
  audit : (Audit.t -> unit) option;
  (* Supplied by the caller rather than computed here, so this library keeps knowing nothing about
     the shape of a telemetry snapshot. Returns a rendered exposition-format document. *)
  metrics : (unit -> string * string) option;
}

(* ───────────────────────── routing ───────────────────────── *)

let split_path p = String.split_on_char '/' p |> List.filter (fun s -> not (String.equal s ""))

let match_segments ~pattern ~actual =
  let rec go ps as_ acc =
    match (ps, as_) with
    | [], [] -> Some (List.rev acc)
    | p :: pt, a :: at ->
      if String.length p > 1 && p.[0] = ':' then
        go pt at ((String.sub p 1 (String.length p - 1), a) :: acc)
      else if String.equal p a then go pt at acc
      else None
    | _ -> None in
    go pattern actual []


let match_route routes ~meth ~path =
  let actual = split_path path in
    List.fold_left
      (fun acc r ->
        match acc with
        | Some _ -> acc
        | None ->
          if r.meth <> meth then None
          else (
            match match_segments ~pattern:(split_path r.path) ~actual with
            | Some params -> Some (r, params)
            | None -> None))
      None routes


(* ───────────────────────── query strings ───────────────────────── *)

let percent_decode s =
  let n = String.length s in
  let b = Buffer.create n in
  let hex c =
    match c with
    | '0' .. '9' -> Char.code c - 48
    | 'a' .. 'f' -> Char.code c - 87
    | 'A' .. 'F' -> Char.code c - 55
    | _ -> -1 in
  let i = ref 0 in
    while !i < n do
      (match s.[!i] with
      | '+' -> Buffer.add_char b ' '
      | '%' when !i + 2 < n && hex s.[!i + 1] >= 0 && hex s.[!i + 2] >= 0 ->
        Buffer.add_char b (Char.chr ((hex s.[!i + 1] * 16) + hex s.[!i + 2])) ;
        i := !i + 2
      | c -> Buffer.add_char b c) ;
      incr i
    done ;
    Buffer.contents b


let parse_query q =
  if String.equal q "" then []
  else
    String.split_on_char '&' q
    |> List.filter_map (fun kv ->
         if String.equal kv "" then None
         else
           match String.index_opt kv '=' with
           | None -> Some (percent_decode kv, "")
           | Some i ->
             Some
               ( percent_decode (String.sub kv 0 i),
                 percent_decode (String.sub kv (i + 1) (String.length kv - i - 1)) ))


(* ───────────────────────── static files ───────────────────────── *)

let content_type path =
  let ext =
    match String.rindex_opt path '.' with
    | None -> ""
    | Some i -> String.lowercase_ascii (String.sub path i (String.length path - i)) in
    match ext with
    | ".html" -> "text/html; charset=utf-8"
    | ".js" -> "application/javascript; charset=utf-8"
    | ".css" -> "text/css; charset=utf-8"
    | ".json" -> "application/json; charset=utf-8"
    | ".svg" -> "image/svg+xml"
    | _ -> "application/octet-stream"


(* Refuse anything that escapes the root. The server binds to loopback, but a traversal bug is a
   traversal bug and this is three lines. *)
let resolve_static ~root ~path:rel =
  let parts = split_path rel in
    if List.exists (fun p -> String.equal p ".." || String.equal p ".") parts then None
    else
      let path = List.fold_left Filename.concat root parts in
        (* Any directory resolves to its index.html, not just the root — otherwise /dashboard/ 404s
           while /dashboard/index.html works, which is the kind of difference nobody types. *)
        Some
          (if Sys.file_exists path && Sys.is_directory path then Filename.concat path "index.html"
           else path)


(* ───────────────────────── clients ───────────────────────── *)

let client_count t = List.length (Atomic.get t.clients)

let rec add_client t entry =
  let cur = Atomic.get t.clients in
    if Atomic.compare_and_set t.clients cur (entry :: cur) then () else add_client t entry


let rec remove_client t id =
  let cur = Atomic.get t.clients in
  let next = List.filter (fun c -> c.id <> id) cur in
    if Atomic.compare_and_set t.clients cur next then () else remove_client t id


let sse_frame payload = "data: " ^ payload ^ "\n\n"

let broadcast t payload =
  let frame = sse_frame payload in
    List.iter
      (fun c ->
        (* A client that has gone away makes [push] raise; drop it rather than let the push loop die
           and take every other client's stream with it. *)
        try c.push (Some frame) with _ -> remove_client t c.id)
      (Atomic.get t.clients)


(* Revocation has to reach open streams too. A stream opened a minute ago holds no credential of its
   own — it was authorised once, at open — so without this it would keep delivering positions and
   P&L to a key that has since been revoked. Run on the push tick, over a list that is almost always
   length one. *)
let drop_revoked_clients t ~now_ns =
  match t.auth with
  | None -> ()
  | Some ks ->
    List.iter
      (fun c ->
        if not (Auth.Keystore.is_live ks ~now_ns ~kid:c.kid) then (
          Log.info (fun m -> m "dropping event stream for revoked or expired key %s" c.kid) ;
          (try c.push None with _ -> ()) ;
          remove_client t c.id))
      (Atomic.get t.clients)


(* ───────────────────────── request handling ───────────────────────── *)

let json_headers =
  Cohttp.Header.of_list
    [
      ("content-type", "application/json; charset=utf-8");
      (* The dashboard is served from the same origin, so CORS is not needed; say so explicitly
         rather than leaving a permissive default in place. *)
      ("cache-control", "no-store");
    ]


(* One optional argument, and [type handler] never has to change. This works because every response
   needing a non-standard header — 401 with [WWW-Authenticate], 429 with [Retry-After] — is produced
   by the dispatcher, not by a handler. Handlers stay header-blind and trivially testable. *)
let respond_json ?(status = 200) ?(headers = []) body =
  let h = List.fold_left (fun acc (k, v) -> Cohttp.Header.replace acc k v) json_headers headers in
    Cohttp_lwt_unix.Server.respond_string
      ~status:(Cohttp.Code.status_of_code status)
      ~headers:h ~body ()


let err ?headers status msg = respond_json ~status ?headers (Json.to_string (Json.error msg))

let www_authenticate ?scope () =
  match scope with
  | None -> [ ("www-authenticate", "Bearer realm=\"algostream\"") ]
  | Some s ->
    [
      ( "www-authenticate",
        Printf.sprintf "Bearer realm=\"algostream\", error=\"insufficient_scope\", scope=\"%s\""
          (Scope.to_string s) );
    ]


let respond_text ?(status = 200) ~content_type body =
  Cohttp_lwt_unix.Server.respond_string
    ~status:(Cohttp.Code.status_of_code status)
    ~headers:
      (Cohttp.Header.of_list [ ("content-type", content_type); ("cache-control", "no-store") ])
    ~body ()


let now_ns () = Int64.of_float (Unix.gettimeofday () *. 1e9)

(* [Authorization: Bearer <key>], or None. *)
let bearer (req : Cohttp.Request.t) =
  match Cohttp.Header.get (Cohttp.Request.headers req) "authorization" with
  | None -> None
  | Some v ->
    let prefix = "Bearer " in
    let n = String.length prefix in
      if String.length v > n && String.equal (String.lowercase_ascii (String.sub v 0 n)) "bearer "
      then Some (String.trim (String.sub v n (String.length v - n)))
      else None


let handle_events t ~principal =
  let stream, push = Lwt_stream.create () in
  let id = Atomic.fetch_and_add t.next_client_id 1 in
    add_client t { id; stream; push; kid = Principal.kid principal } ;
    (* Send the current state immediately so a freshly-opened dashboard is not blank until the next
       tick. *)
    (try push (Some (sse_frame (Json.to_string (t.snapshot ())))) with _ -> ()) ;
    let headers =
      Cohttp.Header.of_list
        [
          ("content-type", "text/event-stream");
          ("cache-control", "no-store");
          ("connection", "keep-alive");
        ] in
      Cohttp_lwt_unix.Server.respond ~status:`OK ~headers
        ~body:(Cohttp_lwt.Body.of_stream stream)
        ()


let handle_static t ~path =
  match t.cfg.static_root with
  | None -> respond_json ~status:404 (Json.to_string (Json.error "no static root configured"))
  | Some root ->
    (match resolve_static ~root ~path with
    | None -> respond_json ~status:400 (Json.to_string (Json.error "bad path"))
    | Some file ->
      if Sys.file_exists file && not (Sys.is_directory file) then
        let headers = Cohttp.Header.of_list [ ("content-type", content_type file) ] in
          Cohttp_lwt_unix.Server.respond_file ~headers ~fname:file ()
      else respond_json ~status:404 (Json.to_string (Json.error "not found")))


(* ───────────────────────── audit ───────────────────────── *)

(* Written from the dispatcher and nowhere else. An audit that individual handlers have to remember
   to call is an audit with holes, and only the dispatcher has all the pieces anyway: principal,
   route pattern, concrete path, params, body and final status. *)
let audit t ~principal ~peer ~meth ~path ~route ~params ~body ~outcome ~status =
  match t.audit with
  | None -> ()
  | Some sink ->
    (try
       sink
         (Audit.make ~ts_ns:(now_ns ()) ~kid:(Principal.kid principal)
            ~label:(Principal.label principal)
            ~scopes:(Scope.Set.to_string (Principal.scopes principal))
            ~peer ~meth ~path ~route ~params ~body ~outcome ~status)
     with exn -> Log.err (fun m -> m "audit sink raised: %s" (Printexc.to_string exn)))


let meth_string = function `GET -> "GET" | `POST -> "POST" | `PUT -> "PUT"

(* The peer address, from the connection cohttp hands us and used to discard. *)
let peer_of_conn (conn : Cohttp_lwt_unix.Server.conn) =
  match fst conn with
  | Conduit_lwt_unix.TCP { ip; port; _ } -> Printf.sprintf "%s:%d" (Ipaddr.to_string ip) port
  | _ -> "-"


let handle_api t ~conn ~req ~meth ~path ~query ~body =
  let peer = peer_of_conn conn in
  let ms = meth_string meth in
    match match_route t.routes ~meth ~path with
    | None -> err 404 ("no route for " ^ path)
    | Some (r, path_params) ->
      let deny ?headers status reason =
        audit t ~principal:Principal.Anonymous ~peer ~meth:ms ~path ~route:r.path
          ~params:path_params ~body ~outcome:(Audit.Denied reason) ~status ;
        err ?headers status reason in
      let run principal =
        try
          let j, status = r.handler { path_params; query = parse_query query; body; principal } in
            (* Only control actions are audited on success. Recording every telemetry poll would
               bury the four events a day that matter under 4 Hz of noise. *)
            if r.scope = Scope.Control then
              audit t ~principal ~peer ~meth:ms ~path ~route:r.path ~params:path_params ~body
                ~outcome:Audit.Allowed ~status ;
            respond_json ~status (Json.to_string j)
        with exn ->
          Log.err (fun m -> m "handler for %s raised: %s" path (Printexc.to_string exn)) ;
          audit t ~principal ~peer ~meth:ms ~path ~route:r.path ~params:path_params ~body
            ~outcome:(Audit.Failed (Printexc.to_string exn))
            ~status:500 ;
          err 500 "handler raised" in
        (match (t.auth, r.scope) with
        (* No keystore: the daemon is running unauthenticated, which it may only do on loopback. *)
        | None, _ -> run Principal.Anonymous
        | Some _, Scope.Public -> run Principal.Anonymous
        | Some ks, required ->
          let n = now_ns () in
            (match Auth.Rate_limit.check t.limiter ~now_ns:n ~peer with
            | Some retry ->
              err
                ~headers:[ ("retry-after", string_of_int retry) ]
                429 "too many failed authentication attempts"
            | None ->
              (match bearer req with
              | None ->
                if Auth.Rate_limit.note_failure t.limiter ~now_ns:n ~peer then
                  deny ~headers:(www_authenticate ()) 401 "rate limited"
                else deny ~headers:(www_authenticate ()) 401 "no credential"
              | Some credential ->
                (match Auth.Keystore.authenticate ks ~now_ns:n ~credential ~required with
                | Ok principal ->
                  Auth.Rate_limit.note_success t.limiter ~peer ;
                  run principal
                | Error (Auth.Keystore.Insufficient_scope s) ->
                  (* The credential was good; the answer is still no. 403, not 401 — retrying with
                     the same key will never help. *)
                  Auth.Rate_limit.note_success t.limiter ~peer ;
                  deny ~headers:(www_authenticate ~scope:s ()) 403
                    (Auth.Keystore.failure_to_string (Auth.Keystore.Insufficient_scope s))
                | Error f ->
                  ignore (Auth.Rate_limit.note_failure t.limiter ~now_ns:n ~peer) ;
                  deny ~headers:(www_authenticate ()) 401 (Auth.Keystore.failure_to_string f)))))


(* [POST /api/stream-ticket] is handled here rather than as a route because it has to read the
   Authorization header, which [request] deliberately does not carry. Same reason [/events] is
   handled here. *)
let handle_stream_ticket t ~req =
  match t.auth with
  | None -> respond_json (Json.to_string (Json.obj [ ("ticket", Json.string "") ]))
  | Some ks ->
    let n = now_ns () in
      (match bearer req with
      | None -> err ~headers:(www_authenticate ()) 401 "no credential"
      | Some credential ->
        (match Auth.Keystore.authenticate ks ~now_ns:n ~credential ~required:Scope.Read with
        | Error f -> err ~headers:(www_authenticate ()) 401 (Auth.Keystore.failure_to_string f)
        | Ok principal ->
          let ticket =
            Auth.Ticket.mint t.tickets ~now_ns:n ~kid:(Principal.kid principal)
              ~scopes:(Principal.scopes principal) in
            respond_json
              (Json.to_string
                 (Json.obj
                    [
                      ("ticket", Json.string ticket);
                      ( "expires_in_s",
                        Json.int (Int64.to_int (Int64.div Auth.Ticket.ttl_ns 1_000_000_000L)) );
                    ]))))


let handle_events_authenticated t ~query =
  match t.auth with
  | None -> handle_events t ~principal:Principal.Anonymous
  | Some _ ->
    (match List.assoc_opt "ticket" (parse_query query) with
    | None -> err ~headers:(www_authenticate ()) 401 "the event stream needs a ticket"
    | Some ticket ->
      (match Auth.Ticket.redeem t.tickets ~now_ns:(now_ns ()) ~ticket with
      (* Unknown, already used and expired are deliberately not distinguished: the answer is 401
         either way, and saying which would tell an attacker whether a guess was ever valid. *)
      | None -> err ~headers:(www_authenticate ()) 401 "invalid or expired ticket"
      | Some principal -> handle_events t ~principal))


(* Not an ordinary route: the exposition format is text/plain, and [handler] returns JSON. Gated on
   [Read] like any other observation — Prometheus sends a bearer token via [authorization] in its
   scrape config, so this costs the operator one config line and stops the metrics endpoint being
   the one unauthenticated hole in the surface. *)
let handle_metrics t ~req =
  match t.metrics with
  | None -> err 404 "no metrics source configured"
  | Some render ->
    let serve () =
      let content_type, body = render () in
        respond_text ~content_type body in
      (match t.auth with
      | None -> serve ()
      | Some ks ->
        (match bearer req with
        | None -> err ~headers:(www_authenticate ()) 401 "no credential"
        | Some credential ->
          (match
             Auth.Keystore.authenticate ks ~now_ns:(now_ns ()) ~credential ~required:Scope.Read
           with
          | Ok _ -> serve ()
          | Error f -> err ~headers:(www_authenticate ()) 401 (Auth.Keystore.failure_to_string f))))


let callback t conn (req : Cohttp.Request.t) body =
  let uri = Cohttp.Request.uri req in
  let path = Uri.path uri in
  let query = match Uri.verbatim_query uri with Some q -> q | None -> "" in
  let meth =
    match Cohttp.Request.meth req with
    | `GET -> Some `GET
    | `POST -> Some `POST
    | `PUT -> Some `PUT
    | _ -> None in
  (* Belt and braces against a page the operator has open in another tab. Requiring a bearer header
     already defeats it — a cross-origin fetch that sets Authorization triggers a preflight, and we
     send no Access-Control-Allow-* — but this closes the door without depending on the browser
     getting preflight logic right. *)
  let origin_ok =
    match Cohttp.Header.get (Cohttp.Request.headers req) "origin" with
    | None -> true
    | Some o ->
      let expected = Printf.sprintf "http://%s:%d" t.cfg.host t.cfg.port in
        String.equal o expected in
    Lwt.bind (Cohttp_lwt.Body.to_string body) (fun body ->
      match meth with
      | None -> err 405 "method not allowed"
      | Some meth ->
        if (meth = `POST || meth = `PUT) && not origin_ok then
          err 403 "cross-origin request refused"
        else if String.equal path "/events" && meth = `GET then handle_events_authenticated t ~query
        else if String.equal path "/api/stream-ticket" && meth = `POST then
          handle_stream_ticket t ~req
        else if String.equal path "/metrics" && meth = `GET then handle_metrics t ~req
        else if String.length path >= 4 && String.sub path 0 4 = "/api" then
          handle_api t ~conn ~req ~meth ~path ~query ~body
        else if meth = `GET then handle_static t ~path
        else err 404 "not found")


(* ───────────────────────── lifecycle ───────────────────────── *)

let is_loopback h = String.equal h "127.0.0.1" || String.equal h "localhost" || String.equal h "::1"

(* A warning was the wrong control here, and it is worth saying why the answer changed.

   This server originally logged a warning on a non-loopback bind and carried on. Two things made
   that untenable. The socket was not actually loopback-bound in the first place, so the warning was
   the only thing standing between an unauthenticated control surface and the network — and it was
   printed by a daemon that usually runs detached, where nobody reads it. Now that authentication
   exists there is a real answer instead of a caveat: exposing strategy controls to a network with
   no credential at all is refused outright.

   [allow_insecure] exists because the operator may genuinely want a plaintext bind behind a reverse
   proxy that terminates TLS. It is named to read badly in shell history, which is the point. *)
type bind_error = string

let check_bind ~config ~auth ~allow_insecure : (unit, bind_error) result =
  if is_loopback config.host then Ok ()
  else
    match (auth, allow_insecure) with
    | None, _ ->
      Error
        (Printf.sprintf
           "refusing to bind the dashboard API to %s with no keystore: it exposes strategy \
            start/stop controls with no credential. Create keys with algostream-keyctl and pass \
            --auth-keys, or bind to 127.0.0.1."
           config.host)
    | Some _, false ->
      Error
        (Printf.sprintf
           "refusing to bind to %s in plaintext: bearer tokens would cross the network in the \
            clear. Put a TLS-terminating reverse proxy in front (see docs/guides/security.md), or \
            pass --insecure-plaintext-bind if you accept that."
           config.host)
    | Some _, true ->
      Log.warn (fun m ->
        m "binding to %s in plaintext at your request — bearer tokens are exposed on the wire"
          config.host) ;
      Ok ()


let create ~config ~routes ~snapshot ~auth ~audit ~metrics =
  {
    cfg = config;
    routes;
    snapshot;
    clients = Atomic.make [];
    next_client_id = Atomic.make 0;
    auth;
    tickets = Auth.Ticket.create ();
    limiter = Auth.Rate_limit.create ();
    audit;
    metrics;
  }


let config t = t.cfg

let attach t host =
  Lwt_host.attach host ~name:"api.server" (fun ~stop ->
    (* [`TCP (`Port p)] carries no address. Conduit resolves a context whose [src] is [None] to
       [INADDR_ANY], so passing the mode alone binds 0.0.0.0 no matter what [cfg.host] says — which
       is how this server came to listen on every interface while logging and documenting loopback.
       The bind address lives on the context, not the mode, so [cfg.host] has to be resolved into
       one. *)
    Lwt.bind (Conduit_lwt_unix.init ~src:t.cfg.host ()) (fun conduit ->
      let ctx = Cohttp_lwt_unix.Net.init ~ctx:conduit () in
      let mode = `TCP (`Port t.cfg.port) in
      let server = Cohttp_lwt_unix.Server.make ~callback:(callback t) () in
        Log.info (fun m -> m "dashboard API on http://%s:%d/" t.cfg.host t.cfg.port) ;
        (* [stop] resolves when the host is shutting down; cohttp takes it directly. *)
        Cohttp_lwt_unix.Server.create ~ctx ~stop ~mode server)) ;
  Lwt_host.attach host ~name:"api.push" (fun ~stop ->
    let rec loop () =
      if not (Lwt.is_sleeping stop) then Lwt.return_unit
      else
        Lwt.bind
          (Lwt.pick [ Lwt_unix.sleep t.cfg.push_interval_s; stop ])
          (fun () ->
            if not (Lwt.is_sleeping stop) then (
              (* Close every stream so the connections end rather than hanging. *)
              List.iter (fun c -> try c.push None with _ -> ()) (Atomic.get t.clients) ;
              Lwt.return_unit)
            else (
              drop_revoked_clients t ~now_ns:(now_ns ()) ;
              (if client_count t > 0 then
                 try broadcast t (Json.to_string (t.snapshot ()))
                 with exn ->
                   Log.err (fun m -> m "snapshot for push raised: %s" (Printexc.to_string exn))) ;
              loop ())) in
      loop ())
