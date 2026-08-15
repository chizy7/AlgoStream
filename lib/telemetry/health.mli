(** Named health checks with staleness budgets.

    A monitoring dashboard needs to distinguish three things a raw counter cannot: working, working
    badly, and not working. Every check answers with one of those, and carries the reason as text so
    the UI never has to guess why something is amber.

    Checks are pure functions supplied by the caller. This module deliberately knows nothing about
    ingestion, processors or strategies — it is handed closures, which keeps [algostream.telemetry]
    dependent on nothing but the event bus. *)

type status =
  | Ok
  | Degraded of string
  | Failed of string

val status_to_string : status -> string

(** Rank for aggregation: [Ok] < [Degraded] < [Failed]. *)
val severity_rank : status -> int

(** Worst status in a list; [Ok] for the empty list. *)
val worst : status list -> status

type check = {
  name : string;
  run : unit -> status;
}

type report = {
  check_name : string;
  status : status;
  checked_at_ns : int64;
}

(** [stale ~what ~age_ns ~degraded_after_ns ~failed_after_ns] is the shape almost every feed check
    takes: fresh is [Ok], quiet is [Degraded], silent is [Failed].

    [age_ns = Int64.max_int] means "nothing has ever arrived", which reports [Failed] rather than
    being treated as infinitely stale — it is a different problem and worth different wording. *)
val stale :
  what:string -> age_ns:int64 -> degraded_after_ns:int64 -> failed_after_ns:int64 -> status

(** [threshold ~what ~value ~degraded_above ~failed_above ~unit_] for any metric where bigger is
    worse — queue depth, drop rate, latency. *)
val threshold :
  what:string -> value:float -> degraded_above:float -> failed_above:float -> unit_:string -> status

(** Run every check, stamping each result with [ts_ns]. A check that raises is reported as [Failed]
    rather than propagating: one broken probe must not take down the health endpoint. *)
val run_all : check list -> ts_ns:int64 -> report list

(** Overall status: the worst of the reports. *)
val overall : report list -> status
