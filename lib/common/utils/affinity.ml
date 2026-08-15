type error =
  [ `Unsupported of string
  | `Failed of string
  ]

external supported_stub : unit -> bool = "algostream_affinity_supported"

external pin_stub : int -> unit = "algostream_affinity_pin"

external cpu_count_stub : unit -> int = "algostream_affinity_cpu_count"

let error_to_string = function
  | `Unsupported msg -> "unsupported: " ^ msg
  | `Failed msg -> "failed: " ^ msg


(* Both are compile-time constants on the C side, so read them once rather than paying a stub call
   per lookup. *)
let available = supported_stub ()

let cpu_count = cpu_count_stub ()

let pin core =
  if not available then
    Error
      (`Unsupported
         "cpu pinning is implemented for Linux only; see Affinity's interface for why macOS is not \
          treated as supported")
  else
    try
      pin_stub core ;
      Ok ()
    with
    | Unix.Unix_error (err, fn, _) ->
      Error (`Failed (Printf.sprintf "%s: %s (core %d)" fn (Unix.error_message err) core))
    | Failure msg -> Error (`Failed msg)


(* The remaining cores to hand out, as an immutable list behind an atomic. Popping with
   compare-and-set rather than a mutex keeps [claim] safe against two Domains starting at once
   without adding a lock to a module that has no other reason to need one. *)
let plan : int list Atomic.t = Atomic.make []

let set_plan cores = Atomic.set plan cores

let rec take_next () =
  match Atomic.get plan with
  | [] -> None
  | core :: rest as current ->
    (* Retry on contention: two Domains starting simultaneously must not receive the same core. *)
    if Atomic.compare_and_set plan current rest then Some core else take_next ()


(* Outcomes accumulate newest-first and are reversed in [report], so [claim] stays a constant-time
   push rather than walking the list. *)
let outcomes : (string * (int, error) result) list Atomic.t = Atomic.make []

let rec record entry =
  let current = Atomic.get outcomes in
    if not (Atomic.compare_and_set outcomes current (entry :: current)) then record entry


let claim ~name =
  match take_next () with
  | None -> ()
  | Some core -> record (name, Result.map (fun () -> core) (pin core))


let report () = List.rev (Atomic.get outcomes)
