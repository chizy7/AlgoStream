(** Domain worker pool.

    The repo's first parallel-{i compute} construct. All five pre-existing [Domain.spawn] sites
    (event bus dispatcher, analytics, pairs, time-series, ingestion) are single long-lived workers
    that own state and publish snapshots. This is different: a fan-out of independent work items
    across cores.

    {2 The determinism contract}

    If [f i] depends only on [i] and on immutable captured values, then

    {[
      map ~n_domains:1 ~n ~f = map ~n_domains:16 ~n ~f
    ]}

    element for element, bit for bit. Two things make that true: results are written to slot [i] of
    a pre-allocated array rather than appended in completion order, and work is claimed by index
    from an atomic counter so no worker's assignment depends on another's timing. Combined with
    [Rng.substream ~root_seed ~index], a whole Monte Carlo batch reproduces regardless of how many
    cores ran it. [test/montecarlo/test_pool.ml] asserts this at 1, 2, 4 and 8 Domains.

    {2 Scaling, honestly}

    OCaml 5 has a shared heap and [Portfolio] allocates on every [add_trade] via [Map.Poly], so
    engine-level Monte Carlo is GC-bound well before it is core-bound. Expect roughly 4–6× on 8
    cores, not 8×. The bench publishes the measured number rather than claiming linearity. *)

(** [max 1 (Domain.recommended_domain_count () - 1)] — one core is left for the main Domain and the
    GC. *)
val recommended_domains : unit -> int

(** [map ~n_domains ~n ~f] applies [f] to every index in [\[0, n)] and returns the results
    {b in index order}.

    Work is claimed dynamically, so unequal-cost items load-balance. [n_domains <= 1] runs inline on
    the calling Domain with no spawn at all — which is what makes the 1-vs-many determinism test
    meaningful, and what keeps a small batch from paying for thread creation.

    An exception raised by [f i] is captured and re-raised after all work completes, choosing the
    lowest failing index — so a failure is as deterministic as a success. *)
val map : n_domains:int -> n:int -> f:(int -> 'a) -> 'a array

(** As {!map}, but exceptions are returned rather than raised. Use this when a few failed runs out
    of ten thousand should not abort the batch — the Monte Carlo engine reports them as failures and
    carries on. *)
val map_result : n_domains:int -> n:int -> f:(int -> 'a) -> ('a, exn) Stdlib.result array

(** [iter] for side-effecting work with no result. Same claiming and same determinism caveats — note
    that determinism of {i effects} is the caller's problem, since effect order across Domains is
    not constrained. *)
val iter : n_domains:int -> n:int -> f:(int -> unit) -> unit
