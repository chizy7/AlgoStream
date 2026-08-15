module Lwt_host = Algostream_infrastructure_lwt_host.Lwt_host

(* Poll rather than sleep a fixed amount: CI runners are slow enough that a fixed wait either flakes
   or wastes seconds. Mirrors test/analytics/test_processor.ml. *)
let wait_until ?(budget_us = 5_000_000) pred =
  let deadline = Unix.gettimeofday () +. (float_of_int budget_us /. 1_000_000.0) in
  let rec loop () =
    if pred () then true
    else if Unix.gettimeofday () > deadline then false
    else (
      Unix.sleepf 0.001 ;
      loop ()) in
    loop ()


let test_runs_attached_fibers () =
  let host = Lwt_host.create () in
  let a = Atomic.make 0 and b = Atomic.make 0 in
    Lwt_host.attach host ~name:"a" (fun ~stop:_ ->
      Atomic.incr a ;
      Lwt.return_unit) ;
    Lwt_host.attach host ~name:"b" (fun ~stop:_ ->
      Atomic.incr b ;
      Lwt.return_unit) ;
    Alcotest.(check int) "two fibers attached" 2 (Lwt_host.fiber_count host) ;
    Lwt_host.start host ;
    let ran = wait_until (fun () -> Atomic.get a = 1 && Atomic.get b = 1) in
      Lwt_host.stop host ;
      Alcotest.(check bool) "both fibers ran" true ran


let test_stop_promise_releases_a_loop () =
  let host = Lwt_host.create () in
  let ticks = Atomic.make 0 and finished = Atomic.make false in
    Lwt_host.attach host ~name:"loop" (fun ~stop ->
      let rec loop () =
        if not (Lwt.is_sleeping stop) then (
          Atomic.set finished true ;
          Lwt.return_unit)
        else
          Lwt.bind
            (Lwt.pick [ Lwt_unix.sleep 0.005; stop ])
            (fun () ->
              Atomic.incr ticks ;
              loop ()) in
        loop ()) ;
    Lwt_host.start host ;
    let spun = wait_until (fun () -> Atomic.get ticks > 2) in
      Alcotest.(check bool) "loop is running" true spun ;
      Lwt_host.stop host ;
      (* stop joins the Domain, so the fiber has necessarily observed the promise by now. *)
      Alcotest.(check bool) "loop observed the stop promise" true (Atomic.get finished) ;
      Alcotest.(check bool) "host reports stopped" false (Lwt_host.is_running host)


(* A fiber that raises must not take its siblings down: the host logs it and keeps going. *)
let test_raising_fiber_is_isolated () =
  let host = Lwt_host.create () in
  let survivor = Atomic.make 0 in
    Lwt_host.attach host ~name:"bad" (fun ~stop:_ -> failwith "deliberate") ;
    Lwt_host.attach host ~name:"good" (fun ~stop ->
      let rec loop () =
        if not (Lwt.is_sleeping stop) then Lwt.return_unit
        else
          Lwt.bind
            (Lwt.pick [ Lwt_unix.sleep 0.005; stop ])
            (fun () ->
              Atomic.incr survivor ;
              loop ()) in
        loop ()) ;
    Lwt_host.start host ;
    let alive = wait_until (fun () -> Atomic.get survivor > 2) in
      Lwt_host.stop host ;
      Alcotest.(check bool) "sibling kept running after a fiber raised" true alive


let test_attach_after_start_raises () =
  let host = Lwt_host.create () in
    Lwt_host.attach host ~name:"noop" (fun ~stop -> Lwt.bind stop (fun () -> Lwt.return_unit)) ;
    Lwt_host.start host ;
    let raised =
      try
        Lwt_host.attach host ~name:"late" (fun ~stop:_ -> Lwt.return_unit) ;
        false
      with Failure _ -> true in
      Lwt_host.stop host ;
      Alcotest.(check bool) "attach after start raises" true raised


(* The whole reason this module exists: two schedulers in one process corrupt Lwt_engine. *)
let test_second_host_raises () =
  let h1 = Lwt_host.create () in
    Lwt_host.attach h1 ~name:"idle" (fun ~stop -> Lwt.bind stop (fun () -> Lwt.return_unit)) ;
    Lwt_host.start h1 ;
    let h2 = Lwt_host.create () in
      Lwt_host.attach h2 ~name:"idle" (fun ~stop -> Lwt.bind stop (fun () -> Lwt.return_unit)) ;
      let raised =
        try
          Lwt_host.start h2 ;
          false
        with Failure _ -> true in
        Lwt_host.stop h1 ;
        Alcotest.(check bool) "a second concurrent host raises" true raised ;
        (* Once the first host is stopped the guard must be released, or nothing can run again. *)
        let h3 = Lwt_host.create () in
        let ran = Atomic.make false in
          Lwt_host.attach h3 ~name:"after" (fun ~stop:_ ->
            Atomic.set ran true ;
            Lwt.return_unit) ;
          Lwt_host.start h3 ;
          let ok = wait_until (fun () -> Atomic.get ran) in
            Lwt_host.stop h3 ;
            Alcotest.(check bool) "guard released after stop" true ok


let test_stop_is_idempotent_and_safe_unstarted () =
  let never_started = Lwt_host.create () in
    Lwt_host.stop never_started ;
    Alcotest.(check bool) "unstarted host is not running" false (Lwt_host.is_running never_started) ;
    let host = Lwt_host.create () in
      Lwt_host.attach host ~name:"idle" (fun ~stop -> Lwt.bind stop (fun () -> Lwt.return_unit)) ;
      Lwt_host.start host ;
      Alcotest.(check bool) "running after start" true (Lwt_host.is_running host) ;
      Lwt_host.stop host ;
      Lwt_host.stop host ;
      Alcotest.(check bool) "still stopped after a second stop" false (Lwt_host.is_running host)


let suite =
  [
    Alcotest.test_case "runs_attached_fibers" `Quick test_runs_attached_fibers;
    Alcotest.test_case "stop_promise_releases_a_loop" `Quick test_stop_promise_releases_a_loop;
    Alcotest.test_case "raising_fiber_is_isolated" `Quick test_raising_fiber_is_isolated;
    Alcotest.test_case "attach_after_start_raises" `Quick test_attach_after_start_raises;
    Alcotest.test_case "second_host_raises" `Quick test_second_host_raises;
    Alcotest.test_case "stop_idempotent_and_safe_unstarted" `Quick
      test_stop_is_idempotent_and_safe_unstarted;
  ]
