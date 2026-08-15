(** The process's single Lwt scheduler.

    [Lwt_engine] keeps process-global state, so running [Lwt_main.run] from two Domains corrupts
    silently. This module owns the one permitted call site: it spawns a dedicated [Domain.t], runs
    [Lwt_main.run] there, and drives every fiber the rest of the system needs.

    Before this existed the scheduler was owned by [Ingestion_supervisor], which meant nothing else
    could use Lwt — in particular an HTTP server could not run unless ingestion was running. The
    ownership is now explicit and shared.

    Concurrency invariant: this is the ONLY [Lwt_main.run] call site in the project, and CI asserts
    it at file granularity. At most one host may be running per process; [start] raises otherwise.

    {1 Attach before start}

    Fibers are registered with {!attach} and begin when {!start} is called. There is deliberately no
    way to attach to a running host: Lwt values are not safe to touch from another Domain, so
    injecting work into a live scheduler would need a notification channel that nothing here
    currently needs. Wire the system up, then start it. *)

type t

(** A fiber to run under the host. It receives a promise that resolves when the host is stopping;
    long-running loops should select on it so that {!stop} is prompt. *)
type fiber = stop:unit Lwt.t -> unit Lwt.t

val create : unit -> t

(** Register a fiber. [name] appears in log messages when the fiber raises.

    @raise Failure if the host has already been started. *)
val attach : t -> name:string -> fiber -> unit

(** Spawn the Domain and run every attached fiber to completion.

    Returns as soon as the Domain has been spawned — it does not wait for the fibers.

    @raise Failure if this host, or any other host in the process, is already running. *)
val start : t -> unit

(** Signal every fiber to stop, then join the Domain. Safe to call more than once, and safe to call
    on a host that was never started. *)
val stop : t -> unit

(** True between {!start} and {!stop}. *)
val is_running : t -> bool

(** Number of attached fibers. Diagnostic. *)
val fiber_count : t -> int
