type severity =
  | Info
  | Warning
  | Critical

let severity_to_string = function Info -> "info" | Warning -> "warning" | Critical -> "critical"

let severity_rank = function Info -> 0 | Warning -> 1 | Critical -> 2

type t = {
  code : string;
  severity : severity;
  message : string;
  first_raised_ns : int64;
  last_raised_ns : int64;
  count : int;
}

let to_string a =
  Printf.sprintf "[%s] %s: %s (x%d)" (severity_to_string a.severity) a.code a.message a.count


(* The registry is read by the API from another Domain, so the whole map is published as one
   immutable association list via Atomic.set — the same pattern the processors use for snapshots.
   Writes are rare (an alert transition), reads are frequent, and neither needs a lock. *)
type registry = {
  window_ns : int64;
  entries : (string * t) list Atomic.t;
}

let default_window_ns = 30_000_000_000L

let create ?(window_ns = default_window_ns) () = { window_ns; entries = Atomic.make [] }

let rec update t f =
  let cur = Atomic.get t.entries in
  let next, result = f cur in
    if Atomic.compare_and_set t.entries cur next then result else update t f


let raise_alert t ~ts_ns ~code ~severity ~message =
  update t (fun cur ->
    match List.assoc_opt code cur with
    | None ->
      let a =
        { code; severity; message; first_raised_ns = ts_ns; last_raised_ns = ts_ns; count = 1 }
      in
        ((code, a) :: cur, true)
    | Some prev ->
      (* Measured from the start of the current burst, not from the last raise. Comparing against
         [last_raised_ns] would mean a condition re-evaluated faster than the window never
         re-notifies at all: each raise pushes the deadline out, so a permanently broken feed would
         alert once and then go quiet forever. *)
      let fresh = Int64.compare (Int64.sub ts_ns prev.first_raised_ns) t.window_ns >= 0 in
      let a =
        {
          prev with
          severity;
          message;
          last_raised_ns = ts_ns;
          count = prev.count + 1;
          (* A re-notification restarts the run, so the "first raised" of the current burst moves
             with it; otherwise a long-running condition would report an ever-growing age that says
             nothing about the present. *)
          first_raised_ns = (if fresh then ts_ns else prev.first_raised_ns);
        } in
        ((code, a) :: List.remove_assoc code cur, fresh))


let clear t ~code =
  update t (fun cur ->
    if List.mem_assoc code cur then (List.remove_assoc code cur, true) else (cur, false))


let active t =
  let xs = List.map snd (Atomic.get t.entries) in
    List.sort
      (fun a b ->
        let c = compare (severity_rank b.severity) (severity_rank a.severity) in
          if c <> 0 then c else Int64.compare b.last_raised_ns a.last_raised_ns)
      xs


let active_at_least t sev =
  List.filter (fun a -> severity_rank a.severity >= severity_rank sev) (active t)


let count t = List.length (Atomic.get t.entries)
