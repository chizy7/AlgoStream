(** The dashboard's HTTP API.

    Runs on {!Algostream_infrastructure_lwt_host}, so it shares the process's single Lwt scheduler
    with ingestion instead of starting one of its own. Before the host was extracted this was not
    possible: the ingestion supervisor owned [Lwt_main.run], so nothing else could use Lwt at all.

    {1 Push: Server-Sent Events, not WebSocket}

    The design target was "sub-second updates", by way of WebSocket. This ships SSE instead, and the
    substitution is deliberate.

    The dashboard needs exactly one thing: the server pushing state to the browser several times a
    second. That is what SSE is — a long-lived [text/event-stream] response. It needs no upgrade
    handshake, no frame masking, no SHA-1, no ping/pong keepalive, and no second protocol
    implementation to get wrong; and [EventSource] reconnects on its own, which a WebSocket client
    has to be taught to do. A WebSocket would only earn its complexity if the browser had to send a
    continuous stream back, and it does not — control actions are a handful of POSTs a day.

    {1 Security}

    Bound to the address in [config.host], which defaults to [127.0.0.1]. Note that [`TCP (`Port p)]
    carries no address of its own — the bind address lives on the conduit context, which {!attach}
    builds from [config.host]. Passing the mode alone binds [INADDR_ANY].

    Requests carry an {!Algostream_infrastructure_auth.Principal.t}. Every {!route} declares the
    {!Algostream_infrastructure_auth.Scope.t} it requires, and the dispatcher enforces it before the
    handler runs — so a handler never sees an under-scoped principal, and the [principal] field is
    there to attribute, not to re-check.

    Credentials are [Authorization: Bearer] and nothing else, which is load-bearing rather than
    conventional. A cross-origin [fetch] that sets [Authorization] is not a CORS simple request, so
    it triggers a preflight; this server sends no [Access-Control-Allow-*] headers, the preflight
    fails, and a page the operator happens to have open in another tab cannot forge a control
    action. That is a complete CSRF defence with no CSRF machinery — and it is exactly what a cookie
    session would throw away.

    The one endpoint that cannot send a header is [/events], since [EventSource] cannot set one. It
    uses a single-use, 30-second ticket from [POST /api/stream-ticket] instead; see
    {!Algostream_infrastructure_auth.Ticket}.

    Passing [~auth:None] runs unauthenticated, which is why {!check_bind} exists.

    Every number it serves is paper-traded — see {!Algostream_runtime.Instance}. *)

module Lwt_host = Algostream_infrastructure_lwt_host.Lwt_host
module Auth = Algostream_infrastructure_auth
module Scope = Auth.Scope
module Principal = Auth.Principal
module Keystore = Auth.Keystore
module Audit_record = Algostream_infrastructure_persistence.Audit_record

type t

(** A request, after path matching. *)
type request = {
  path_params : (string * string) list;  (** from [:name] segments *)
  query : (string * string) list;
  body : string;
  principal : Principal.t;
    (** Who is calling. Already authorised for this route's {!route.scope} — the dispatcher denies
        before the handler runs. Present so a handler can attribute an action, not so it can
        re-check one. *)
}

(** A handler returns the JSON body and the HTTP status to send with it. *)
type handler = request -> Json.t * int

type route = {
  meth : [ `GET | `POST | `PUT ];
  path : string;  (** e.g. ["/api/strategies/:id/pause"] *)
  scope : Scope.t;
    (** Mandatory, and deliberately not optional with a default. A route that forgets to declare its
        authorisation should fail to compile: with a default, the failure mode is a new endpoint
        silently inheriting [Read], and the next control endpoint someone adds is exactly where
        silence is expensive. The cost is that adding this field touched every route literal, which
        is the point — the diff enumerated them. *)
  handler : handler;
}

type config = {
  host : string;  (** default ["127.0.0.1"] *)
  port : int;  (** default 8080 *)
  static_root : string option;  (** directory served at [/]; [None] serves the API only *)
  push_interval_s : float;  (** SSE cadence; default 0.25, i.e. 4 Hz *)
}

val default_config : config

(** Build a server. Does not listen yet — {!attach} it to a host, then start the host.

    [snapshot] is polled at [push_interval_s] and pushed to every connected SSE client. Keep it
    cheap: it runs on the Lwt scheduler shared with ingestion.

    [auth] of [None] serves every route without a credential; [check_bind] is what stops that
    reaching a network. [audit] of [None] records nothing. Both [None] reproduces the
    unauthenticated behaviour this server had before the auth layer existed, which keeps [make dash]
    and the test suite working unchanged.

    [metrics] returns [(content_type, body)] for [GET /metrics] and is supplied by the caller so
    this library need not know what a telemetry snapshot looks like. It is not a {!route} because
    the exposition format is [text/plain] while a {!handler} returns JSON, and it is gated on
    {!Scope.Read} like any other observation. *)
val create :
  config:config ->
  routes:route list ->
  snapshot:(unit -> Json.t) ->
  auth:Keystore.t option ->
  audit:(Audit_record.t -> unit) option ->
  metrics:(unit -> string * string) option ->
  t

(** Whether this configuration may listen at all.

    [Ok ()] for any loopback bind. Otherwise [Error] with an operator-readable reason: binding a
    control surface to a network with no keystore is refused, and so is a plaintext bind with one
    unless [allow_insecure] says the operator accepts bearer tokens crossing the wire. Call before
    {!attach}; the daemon exits non-zero on [Error].

    A warning would not be enough here: the daemon usually runs detached, so nobody reads one. *)
val check_bind :
  config:config -> auth:Keystore.t option -> allow_insecure:bool -> (unit, string) result

(** Register the listener and the push loop on the host. Must be called before [Lwt_host.start]. *)
val attach : t -> Lwt_host.t -> unit

(** Number of currently connected event-stream clients. *)
val client_count : t -> int

val config : t -> config

(** Route matching, exposed for testing: returns the handler and extracted path params. *)
val match_route :
  route list ->
  meth:[ `GET | `POST | `PUT ] ->
  path:string ->
  (route * (string * string) list) option

(** Parse a query string ([a=1&b=2], no leading [?]). Percent-decodes both sides. *)
val parse_query : string -> (string * string) list

(** Resolve a request path against a static root. [None] when the path tries to escape the root. A
    directory resolves to its [index.html]. Exposed for testing. *)
val resolve_static : root:string -> path:string -> string option
