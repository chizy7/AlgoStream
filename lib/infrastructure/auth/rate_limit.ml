let max_failures = 5

let window_ns = 60_000_000_000L

type peer_state = {
  mutable failures : int;
  mutable first_failure_ns : int64;
  mutable reported : bool;  (** the one audit record for this window has been written *)
}

type t = { peers : (string, peer_state) Hashtbl.t }

let create () = { peers = Hashtbl.create 16 }

let get t peer =
  match Hashtbl.find_opt t.peers peer with
  | Some s -> s
  | None ->
    let s = { failures = 0; first_failure_ns = 0L; reported = false } in
      Hashtbl.replace t.peers peer s ;
      s


(* A window that has fully elapsed is forgotten rather than decayed. The counter exists to stop a
   burst, not to keep a reputation. *)
let expire ~now_ns s =
  if s.failures > 0 && Int64.compare (Int64.sub now_ns s.first_failure_ns) window_ns >= 0 then (
    s.failures <- 0 ;
    s.first_failure_ns <- 0L ;
    s.reported <- false)


let check t ~now_ns ~peer =
  match Hashtbl.find_opt t.peers peer with
  | None -> None
  | Some s ->
    expire ~now_ns s ;
    if s.failures < max_failures then None
    else
      let remaining_ns = Int64.sub window_ns (Int64.sub now_ns s.first_failure_ns) in
      let secs = Int64.to_int (Int64.div (Int64.add remaining_ns 999_999_999L) 1_000_000_000L) in
        Some (max 1 secs)


let note_failure t ~now_ns ~peer =
  let s = get t peer in
    expire ~now_ns s ;
    if s.failures = 0 then s.first_failure_ns <- now_ns ;
    s.failures <- s.failures + 1 ;
    if s.failures >= max_failures && not s.reported then (
      s.reported <- true ;
      true)
    else false


let note_success t ~peer = Hashtbl.remove t.peers peer

let tracked_peers t = Hashtbl.length t.peers
