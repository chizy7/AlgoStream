(** Top-level supervisor for the market-data ingestion subsystem.

    Runs every configured exchange connection as a set of Lwt fibers under
    {!Algostream_infrastructure_lwt_host.Lwt_host}, which owns the process's single [Lwt_main.run].
    The bus passed in must be live for the supervisor's lifetime.

    Use {!start} to run ingestion on its own private host — that is what [algostream-ingest] does.
    Use {!attach} when something else in the process also needs Lwt (the HTTP API, for instance) so
    that one scheduler serves both. *)

type entry = {
  em : (module Exchange.S);
  config : Algostream_common_config.Exchange_config.t;
}

type t

type per_exchange_stats = {
  exchange : string;
  data_quality : Data_quality.stats;
  bus_drops : int64;
  critical_drops : int64;
  connection : Connection_supervisor.mirror option;
    (** Connection state and time since the last message. [None] until the connector fiber has
        started, which is the only window where nothing is known yet.

        This is what distinguishes a feed that is quiet from one that never connected — the counters
        above cannot, since a feed that has produced nothing has dropped nothing either. *)
}

(** Register ingestion's fibers on a host the caller owns. The caller is responsible for
    [Lwt_host.start] and [Lwt_host.stop]; {!stop} here only marks ingestion stopped and returns the
    latest stats.

    @raise Failure if [host] has already been started. *)
val attach :
  host:Algostream_infrastructure_lwt_host.Lwt_host.t ->
  bus:Algostream_infrastructure_event_bus.Event_bus.t ->
  entries:entry list ->
  unit ->
  t

(** Create a private host, attach ingestion to it and start it. Returns once the Domain is spawned.

    @raise Failure if another Lwt host is already running in this process. *)
val start : bus:Algostream_infrastructure_event_bus.Event_bus.t -> entries:entry list -> unit -> t

(** Signal stop and, when this supervisor owns its host, join it. Returns the final stats snapshot.
    Safe to call twice. *)
val stop : t -> per_exchange_stats list

(** Current counters, readable while ingestion is running.

    The counters themselves live on the ingestion Domain; this returns an immutable snapshot
    republished every 250 ms, so a reader on any Domain is race-free but may be up to that stale.
    Before the first publication the list is empty. *)
val live_stats : t -> per_exchange_stats list

val is_running : t -> bool
