(** Report assembly over the analytics primitives.

    Everything numeric here already existed — [Performance.Metrics] computes 27 risk-adjusted
    figures, [Drawdown_analysis] extracts episodes with recovery times, [Attribution] decomposes
    P&L, [Risk_management.Var] prices four VaR methods. What was missing was any way to get them out
    of the process: every one of those layers exposes a [to_string] aimed at a terminal, and nothing
    exposes rows.

    This module turns them into {!Export.value} tables, so the same report renders as CSV for a
    spreadsheet, as JSON for the dashboard, or as text for a log.

    {1 Regulatory reporting}

    A stated goal was "regulatory reporting capabilities". What ships is {!audit_trail}: a complete,
    timestamped record of every simulated order and fill in a documented schema. It is {b not}
    certified against MiFID II RTS 22, CAT, EMIR or any other regime, and nothing here should be
    filed with anyone. Calling an audit export "regulatory reporting" without that sentence would be
    the kind of claim this project takes care not to make. *)

module Metrics = Algostream_performance.Metrics
module Drawdown_analysis = Algostream_performance.Drawdown_analysis
module Attribution = Algostream_performance.Attribution
module Risk_snapshot = Algostream_risk_management.Risk_snapshot
module Var = Algostream_risk_management.Var
module Runtime_snapshot = Algostream_runtime.Snapshot

type table = {
  title : string;
  headers : string list;
  rows : Export.value list list;
}

val render : table -> Export.format -> string

val table_to_string : table -> string

(** {1 Reports} *)

(** Every metric from a NAV curve, one row per metric — the shape a spreadsheet wants. Uses
    [Metrics.to_assoc], whose field order is documented as stable. *)
val performance : nav:(int64 * float) array -> ?periods_per_year:float -> unit -> table

(** Drawdown episodes: peak, trough, recovery, depth and duration. *)
val drawdowns : nav:(int64 * float) array -> ?min_depth:float -> unit -> table

(** Exposure, VaR/ES and any active limit breaches from a live risk snapshot. *)
val risk : Risk_snapshot.t -> table

(** P&L decomposition by whichever key the caller picks. *)
val attribution : Attribution.contribution array -> title:string -> table

(** Positions currently held, across every instance. *)
val positions : Runtime_snapshot.t -> table

(** Fills, newest first. This is the execution-quality view: price, commission and whether the fill
    was maker or taker. *)
val fills : Runtime_snapshot.t -> table

(** The audit trail — see the caveat at the top of this module. Same rows as {!fills} plus the
    identifiers needed to reconcile an order end to end. *)
val audit_trail : Runtime_snapshot.t -> table

(** Everything the runtime knows, flattened for a quick export. *)
val runtime_summary : Runtime_snapshot.t -> table

(** Report names {!by_name} accepts. *)
val names : string list

(** Look a report up by the name used in the API path. *)
val by_name :
  string ->
  runtime:Runtime_snapshot.t ->
  risk_snapshot:Risk_snapshot.t option ->
  (table, string) result
