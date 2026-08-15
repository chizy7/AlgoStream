(** Pinning a Domain to a CPU core.

    A trading process spends its time moving events between a small number of long-lived Domains —
    the bus dispatcher, each processor's drain loop, the runtime, the Lwt host. Left alone, the
    scheduler migrates those threads between cores, and every migration costs a cold L1/L2 and a
    fresh set of TLB misses on the ring buffers they were just walking. Pinning removes the
    migration.

    {1 What this actually does, per platform}

    Only Linux is real. [sched_setaffinity] with a pid of 0 binds the {b calling thread}, which is
    what makes this usable from inside a Domain: each Domain pins itself from its own entry point
    and leaves its siblings alone.

    Everywhere else — macOS included — {!pin} returns [`Unsupported] without attempting anything.
    macOS does expose [THREAD_AFFINITY_POLICY] through [thread_policy_set], and the unbuilt
    [benchmark_stubs.c] calls it, but it is an {i advisory hint} that groups threads into affinity
    sets rather than binding one to a core, and Apple Silicon ignores it altogether. Reporting
    success for a call that does nothing is worse than reporting that the platform cannot do it, so
    this module does the latter. CI runs Linux, so the path that matters is the tested one.

    {1 Why this is opt-in}

    Pinning is a pessimisation on a machine you do not own. If the core you pick is shared with
    another tenant, or the box has fewer cores than the process has Domains, you have traded the
    scheduler's global view for a fixed guess and will usually lose. So nothing here is called
    unless an operator asks for it — see the [--pin-cores] flag on the daemon — and the default is
    off. {!cpu_count} is the honest input to that decision. *)

(** Why a pin did not happen. Distinguishing the two matters: [`Unsupported] is a property of the
    machine and should be reported once at startup, while [`Failed] means the kernel refused a
    specific request — usually a core index that does not exist — and is an operator error worth
    surfacing loudly. *)
type error =
  [ `Unsupported of string
  | `Failed of string
  ]

val error_to_string : error -> string

(** Whether {!pin} can do anything on this build. Compile-time, not a runtime probe. *)
val available : bool

(** Online cores, from [sysconf(_SC_NPROCESSORS_ONLN)]. Real on every platform, unlike {!pin}, and
    at least [1] — a fallback rather than a [0] that would invite a division by zero downstream. *)
val cpu_count : int

(** [pin core] binds the calling thread to [core].

    Call it from inside the Domain that should be pinned; calling it on another Domain's behalf is
    not possible and not meaningful. Never raises: a kernel refusal, an out-of-range core, and an
    unsupported platform all come back as [Error]. *)
val pin : int -> (unit, error) result

(** {1 Handing cores out to Domains}

    A Domain can only pin itself, but the operator's core plan arrives at the top of [main] — and
    the Domains are spawned several libraries deep, inside [Event_bus.start], each processor's
    [start], the runtime supervisor and the Lwt host. Threading a core number through six
    constructors would put a tuning knob into six public interfaces that have nothing to do with
    tuning.

    So the plan is set once, process-wide, and each Domain claims from it as it starts. The mutable
    state is safe despite the usual objection: {!set_plan} is called before any Domain exists, and
    {!claim} is an atomic pop. *)

(** [set_plan cores] sets the pool {!claim} draws from, in order. Call once, from the main Domain,
    before anything is spawned. An empty list — the default — disables pinning entirely, which is
    why nothing happens unless an operator asks. *)
val set_plan : int list -> unit

(** [claim ~name] takes the next core from the plan, pins the calling thread to it, and records the
    outcome under [name]. One line at the top of a Domain's entry point.

    Does nothing when no plan was set or the plan is exhausted — the ordinary case, and not an
    error: a plan shorter than the number of Domains deliberately pins the first few and leaves the
    rest to the scheduler.

    Nothing is logged from here. [algostream.common.utils] depends on neither [logs] nor anything
    else and that is worth keeping, and half the callers do not link [logs] either. The outcome goes
    to {!report} instead, which the daemon prints once at startup — one legible summary of what got
    pinned where, rather than six lines scattered through the boot sequence. Reporting matters:
    silently continuing unpinned is how you end up believing in a configuration you do not have. *)
val claim : name:string -> unit

(** What {!claim} did, in call order. Empty when pinning was never requested. *)
val report : unit -> (string * (int, error) result) list
