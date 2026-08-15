(** The listener must bind the address in [config.host], not every interface.

    It originally bound [0.0.0.0] unconditionally: [`TCP (`Port p)] carries no address, and a
    conduit context with [src = None] resolves that to [INADDR_ANY]. So [--http-host 127.0.0.1] —
    the default — suppressed the non-loopback warning while the socket stayed reachable from the
    network, with unauthenticated strategy start/stop controls behind it. [server.mli] documented
    loopback binding that was not happening.

    Testing this needs care, because the obvious check does not discriminate. Binding a second
    socket to [0.0.0.0:port] fails with [EADDRINUSE] whether the server holds [0.0.0.0:port] or
    [127.0.0.1:port] — the two conflict. What separates them is binding a {i specific non-loopback}
    address on the same port: that succeeds only if the server left it free, i.e. only if the server
    really is loopback-only. *)

module Net = Algostream_infrastructure_network
module Server = Net.Server
module Json = Net.Json
module Lwt_host = Algostream_infrastructure_lwt_host.Lwt_host

(* Pick a port unlikely to collide with anything else on the machine or a parallel test run. *)
let port = 18771

(** The local address the routing table would use to reach the outside world.

    A [connect] on a UDP socket sends nothing — it only fixes the peer, which is enough for the
    kernel to choose a source address that [getsockname] then reveals. [None] when the machine has
    no route at all, in which case there is no non-loopback address to test against and the check
    below is skipped rather than failed. *)
let non_loopback_addr () =
  let s = Unix.socket Unix.PF_INET Unix.SOCK_DGRAM 0 in
    Fun.protect
      ~finally:(fun () -> try Unix.close s with _ -> ())
      (fun () ->
        try
          Unix.connect s (Unix.ADDR_INET (Unix.inet_addr_of_string "8.8.8.8", 53)) ;
          match Unix.getsockname s with
          | Unix.ADDR_INET (a, _) when a <> Unix.inet_addr_loopback -> Some a
          | _ -> None
        with _ -> None)


let can_bind addr =
  let s = Unix.socket Unix.PF_INET Unix.SOCK_STREAM 0 in
    Fun.protect
      ~finally:(fun () -> try Unix.close s with _ -> ())
      (fun () ->
        try
          (* Deliberately no SO_REUSEADDR: we want to observe the conflict, not work around it. *)
          Unix.bind s (Unix.ADDR_INET (addr, port)) ;
          true
        with Unix.Unix_error _ -> false)


let connects addr =
  let s = Unix.socket Unix.PF_INET Unix.SOCK_STREAM 0 in
    Fun.protect
      ~finally:(fun () -> try Unix.close s with _ -> ())
      (fun () ->
        try
          Unix.connect s (Unix.ADDR_INET (addr, port)) ;
          true
        with Unix.Unix_error _ -> false)


(* Poll rather than sleep a fixed amount: CI runners are slow and a fixed wait is either flaky or
   wasteful. Same discipline as test/infrastructure/lwt_host. *)
let wait_until ~budget_s f =
  let deadline = Unix.gettimeofday () +. budget_s in
  let rec go () =
    if f () then true
    else if Unix.gettimeofday () > deadline then false
    else (
      Unix.sleepf 0.02 ;
      go ()) in
    go ()


let with_server ~host f =
  let cfg = { Server.default_config with host; port; static_root = None } in
  let routes =
    [
      {
        Server.meth = `GET;
        path = "/api/ping";
        scope = Algostream_infrastructure_auth.Scope.Public;
        handler = (fun _ -> (Json.obj [ ("ok", Json.bool true) ], 200));
      };
    ] in
  let server =
    Server.create ~config:cfg ~routes
      ~snapshot:(fun () -> Json.obj [])
      ~auth:None ~audit:None ~metrics:None in
  let host_t = Lwt_host.create () in
    Server.attach server host_t ;
    Lwt_host.start host_t ;
    Fun.protect
      ~finally:(fun () ->
        Lwt_host.stop host_t ;
        (* Give the listener a moment to actually release the port, so a following test that binds
           the same number is not racing it. *)
        ignore (wait_until ~budget_s:2.0 (fun () -> not (connects Unix.inet_addr_loopback))))
      (fun () ->
        if not (wait_until ~budget_s:5.0 (fun () -> connects Unix.inet_addr_loopback)) then
          Alcotest.fail "server never came up on loopback" ;
        f ())


let loopback_bind_is_loopback_only () =
  with_server ~host:"127.0.0.1" (fun () ->
    Alcotest.(check bool) "loopback accepts connections" true (connects Unix.inet_addr_loopback) ;
    match non_loopback_addr () with
    | None ->
      (* No routable interface — nothing to prove against, and failing here would just make the
         suite depend on the network. *)
      ()
    | Some addr ->
      Alcotest.(check bool)
        (Printf.sprintf "%s:%d is left free by a loopback-bound server"
           (Unix.string_of_inet_addr addr) port)
        true (can_bind addr))


let suite =
  [ Alcotest.test_case "loopback_bind_is_loopback_only" `Slow loopback_bind_is_loopback_only ]
