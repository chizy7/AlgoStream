(** Parameter search.

    Every searcher takes an [eval] callback rather than a strategy and a data source. That keeps the
    search algorithms independent of what is being evaluated — walk-forward passes an [eval] closed
    over one fold's data, cross-validation passes one closed over one split, and the unit tests pass
    a closed-form function with a known optimum.

    Evaluation runs through [Montecarlo.Pool], indexed by trial number, so results do not depend on
    how many Domains ran the search. Seed each trial's backtest from
    [substream ~root_seed ~index:trial] and the whole search reproduces. *)

module Metrics = Algostream_performance.Metrics
module Rng = Algostream_rng.Rng

type trial = {
  index : int;
  params : (string * float) list;
  metrics : Metrics.t option;  (** [None] when the evaluation failed *)
  score : float;  (** [neg_infinity] on failure *)
  error : string option;
}

type report = {
  objective : string;
  trials : trial array;  (** in trial-index order, never in completion order *)
  best : trial option;
  n_evaluated : int;
  n_failed : int;
    (** Standard deviation of scores across trials — the input [Overfitting.deflated_sharpe_ratio]
        needs for [trial_sharpe_stdev]. *)
  score_stdev : float;
}

type eval = (string * float) list -> Metrics.t

(** {2 Shared primitives}

    Exposed so {!Genetic} builds its report exactly the way every other strategy here does. A second
    copy of this logic would be free to drift, and the fields it fills — [n_evaluated] above all —
    are what {!Overfitting.deflated_sharpe_ratio} charges a search for. *)

(** Score a batch of points through the pool. Results come back in point order whatever order they
    finished in, and a point whose evaluation raised becomes a failed trial rather than taking the
    batch down. *)
val evaluate :
  points:(string * float) list array ->
  objective:Objective.t ->
  eval:eval ->
  n_domains:int ->
  trial array

(** Summarise trials into a report: best non-failed trial, failure count, score dispersion. *)
val assemble : objective:Objective.t -> trials:trial array -> report

(** Exhaustive grid. Returns [`Too_large n] rather than sampling a subset, so a caller never
    mistakes a partial sweep for a full one. *)
val grid :
  space:Search_space.t ->
  objective:Objective.t ->
  eval:eval ->
  n_domains:int ->
  max_points:int ->
  (report, [ `Too_large of int ]) Stdlib.result

(** Uniform random search over [n] points. *)
val random :
  space:Search_space.t ->
  objective:Objective.t ->
  eval:eval ->
  n_domains:int ->
  n:int ->
  root_seed:int64 ->
  report

(** Latin-hypercube search: same budget as {!random}, exact marginal coverage. Prefer it as the
    default sweep; see {!Search_space.stratified_points} for what it does and does not guarantee. *)
val stratified :
  space:Search_space.t ->
  objective:Objective.t ->
  eval:eval ->
  n_domains:int ->
  n:int ->
  root_seed:int64 ->
  report

(** Coordinate descent from [x0]: repeatedly step to the best grid neighbour until no neighbour
    improves, or [max_passes] is spent. Cheap local polish on a coarse grid winner. *)
val coordinate_descent :
  space:Search_space.t ->
  objective:Objective.t ->
  eval:eval ->
  x0:(string * float) list ->
  max_passes:int ->
  report

(** Local refinement via the existing [Advanced_models.Nelder_mead].

    {b Hard limit of 4 continuous dimensions}, which is [Nelder_mead]'s own documented bound — above
    that it degrades badly, so this returns [Error `Too_many_dimensions] rather than running and
    quietly reporting a poor optimum as if it were a good one. Use it to polish the best point from
    a grid or Latin-hypercube sweep, never as a global search. *)
val nelder_mead_refine :
  space:Search_space.t ->
  objective:Objective.t ->
  eval:eval ->
  x0:(string * float) list ->
  (report, [ `Too_many_dimensions of int ]) Stdlib.result

val report_to_string : report -> string
