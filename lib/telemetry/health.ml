type status =
  | Ok
  | Degraded of string
  | Failed of string

let status_to_string = function
  | Ok -> "ok"
  | Degraded r -> "degraded: " ^ r
  | Failed r -> "failed: " ^ r


let severity_rank = function Ok -> 0 | Degraded _ -> 1 | Failed _ -> 2

let worst xs =
  List.fold_left (fun acc s -> if severity_rank s > severity_rank acc then s else acc) Ok xs


type check = {
  name : string;
  run : unit -> status;
}

type report = {
  check_name : string;
  status : status;
  checked_at_ns : int64;
}

let ns_to_s ns = Int64.to_float ns /. 1_000_000_000.0

let stale ~what ~age_ns ~degraded_after_ns ~failed_after_ns =
  if Int64.equal age_ns Int64.max_int then Failed (Printf.sprintf "%s: no data received yet" what)
  else if Int64.compare age_ns failed_after_ns >= 0 then
    Failed (Printf.sprintf "%s: silent for %.1fs" what (ns_to_s age_ns))
  else if Int64.compare age_ns degraded_after_ns >= 0 then
    Degraded (Printf.sprintf "%s: last update %.1fs ago" what (ns_to_s age_ns))
  else Ok


let threshold ~what ~value ~degraded_above ~failed_above ~unit_ =
  if value >= failed_above then
    Failed (Printf.sprintf "%s: %.2f%s (limit %.2f%s)" what value unit_ failed_above unit_)
  else if value >= degraded_above then
    Degraded (Printf.sprintf "%s: %.2f%s (warn %.2f%s)" what value unit_ degraded_above unit_)
  else Ok


let run_all checks ~ts_ns =
  List.map
    (fun c ->
      let status =
        try c.run ()
        with exn -> Failed (Printf.sprintf "check raised: %s" (Printexc.to_string exn)) in
        { check_name = c.name; status; checked_at_ns = ts_ns })
    checks


let overall reports = worst (List.map (fun r -> r.status) reports)
