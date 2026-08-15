let src = Logs.Src.create "algostream.infrastructure.lwt_host"

module Log = (val Logs.src_log src : Logs.LOG)

type fiber = stop:unit Lwt.t -> unit Lwt.t

type t = {
  mutable fibers : (string * fiber) list;  (** reversed; order is not significant *)
  stop_flag : bool Atomic.t;
  started : bool Atomic.t;
  joined : bool Atomic.t;
  mutable domain : unit Domain.t option;
}

(* Process-global guard. Two hosts would mean two [Lwt_main.run] calls, which is exactly what this
   module exists to prevent. *)
let global_running = Atomic.make false

let logs_threaded_inited = Atomic.make false

let init_logs_threaded_once () =
  if Atomic.compare_and_set logs_threaded_inited false true then Logs_threaded.enable ()


let create () =
  {
    fibers = [];
    stop_flag = Atomic.make false;
    started = Atomic.make false;
    joined = Atomic.make false;
    domain = None;
  }


let attach t ~name f =
  if Atomic.get t.started then
    failwith "Lwt_host.attach: host already started — attach every fiber before calling start" ;
  t.fibers <- (name, f) :: t.fibers


let fiber_count t = List.length t.fibers

(* Runs on the host Domain. Owns the process's only [Lwt_main.run]. *)
let domain_main t =
  let computation =
    let stop_promise, stop_resolver = Lwt.wait () in
    (* Poll the atomic stop flag; it is set from another Domain, so it cannot be an Lwt
       condition. *)
    let watcher =
      let rec loop () =
        if Atomic.get t.stop_flag then (
          (try Lwt.wakeup_later stop_resolver () with _ -> ()) ;
          Lwt.return_unit)
        else Lwt.bind (Lwt_unix.sleep 0.05) (fun () -> loop ()) in
        loop () in
    (* A fiber that raises must not take the others down with it. *)
    let guarded (name, f) =
      Lwt.catch
        (fun () -> f ~stop:stop_promise)
        (fun exn ->
          Log.err (fun m -> m "fiber %s exited with %s" name (Printexc.to_string exn)) ;
          Lwt.return_unit) in
    let running = List.map guarded t.fibers in
      Lwt.bind (Lwt.join running) (fun () ->
        (* Every fiber has finished on its own; release the watcher so Lwt_main can return. *)
        Atomic.set t.stop_flag true ;
        Lwt.catch (fun () -> watcher) (fun _ -> Lwt.return_unit)) in
    try Lwt_main.run computation
    with exn -> Log.err (fun m -> m "Lwt_main.run aborted: %s" (Printexc.to_string exn))


let start t =
  if not (Atomic.compare_and_set t.started false true) then
    failwith "Lwt_host.start: this host is already started" ;
  if not (Atomic.compare_and_set global_running false true) then (
    Atomic.set t.started false ;
    failwith "Lwt_host.start: another Lwt host is already running in this process") ;
  init_logs_threaded_once () ;
  t.domain <-
    Some
      (Domain.spawn (fun () ->
         Algostream_common_utils.Affinity.claim ~name:"lwt_host" ;
         domain_main t))


let stop t =
  if Atomic.compare_and_set t.joined false true then (
    Atomic.set t.stop_flag true ;
    (match t.domain with None -> () | Some d -> (try Domain.join d with _ -> ())) ;
    t.domain <- None ;
    if Atomic.get t.started then Atomic.set global_running false)


let is_running t = Atomic.get t.started && not (Atomic.get t.joined)
