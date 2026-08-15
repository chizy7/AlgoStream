(** Alert raising with deduplication.

    Nothing in the repo had an alert sink before this. [Risk_alert] exists as a bus payload and is
    published by five sites in [data_ingestion], but its only consumer is a [printf] in
    [bin/ingest.ml]; the risk layer's own breaches are return values that land in a snapshot and
    stop there.

    The problem an alert system actually has to solve is repetition: a degraded feed re-evaluates
    every sample period, and an alert that fires four times a second is noise. A code is therefore
    raised at most once per window, with repeats folded into a count on the existing alert. This is
    the same dedup discipline [Connection_supervisor] already applies to its Risk_alert emission,
    generalised.

    Alerts are edge-triggered by {!raise_alert} and cleared explicitly by {!clear}: a rule that
    stops matching must say so, because "the condition went away" and "the rule stopped being
    evaluated" are different and only the caller can tell them apart. *)

type severity =
  | Info
  | Warning
  | Critical

val severity_to_string : severity -> string

val severity_rank : severity -> int

type t = {
  code : string;  (** stable identifier, e.g. ["FEED_STALE"]; dedup is per code *)
  severity : severity;
  message : string;  (** human-readable, may change between repeats *)
  first_raised_ns : int64;
  last_raised_ns : int64;
  count : int;  (** number of times raised, including suppressed repeats *)
}

val to_string : t -> string

type registry

(** [create ?window_ns ()] — repeats of the same code inside [window_ns] update the existing alert
    rather than producing a new one. Default 30 s, matching the ingestion layer's dedup window. *)
val create : ?window_ns:int64 -> unit -> registry

(** Raise, or fold into an existing alert of the same code.

    Returns [true] when this is a new alert or the window has elapsed — i.e. when a notifier should
    actually tell somebody. Returns [false] when it was folded into an existing one. *)
val raise_alert :
  registry -> ts_ns:int64 -> code:string -> severity:severity -> message:string -> bool

(** Clear one code. Returns [true] if an alert was actually active. *)
val clear : registry -> code:string -> bool

(** Currently active alerts, most severe first, then most recent. *)
val active : registry -> t list

(** Active alerts of at least this severity. *)
val active_at_least : registry -> severity -> t list

val count : registry -> int
