(** Genetic-algorithm parameter tuning.

    Real-valued chromosomes over {!Search_space.t}: tournament selection, blend crossover (BLX-α),
    Gaussian mutation scaled per dimension to its own range, and elitism. Reproducible from
    [root_seed] alone — each generation draws from its own substream, so a run is identical whatever
    the pool's domain count or scheduling, exactly as {!Algostream_montecarlo.Engine} guarantees.

    {2 When this is worth using, and when it is not}

    A GA is a stochastic global search. Its advantage appears in spaces that are high-dimensional,
    multi-modal, or discontinuous. It is {b not} the default here, and for most work
    {!Search.stratified} followed by {!Search.nelder_mead_refine} is the better tool: over a smooth,
    largely unimodal surface both find the same optimum, and the latter pair is cheaper and
    deterministic.

    Where it does earn its place is the case the alternatives cannot cover.
    {!Search.nelder_mead_refine} refuses more than four continuous dimensions
    (['Too_many_dimensions']), so on the reference strategy's eight parameters the shipped path is
    global sampling with {i no local refinement at all}. A GA refines everywhere, at any
    dimensionality.

    Two properties of that reference space are worth knowing before reading too much into a result,
    because both waste evaluations and neither is visible in the box bounds:

    - [use_limit_orders] is thresholded at 0.5 into a boolean, so the surface is a step along that
      axis rather than something a blend operator can descend.
    - [min_half_life_bars] and [max_half_life_bars] carry an ordering constraint that box bounds
      cannot express, so points with the two inverted are sampled and scored as failures. This
      affects {!Search.stratified} identically; it is a property of the representation, not of the
      GA.

    {2 The honest-accounting requirement}

    A GA's real output is {i more evaluations}, and on a fixed history more evaluations is more
    overfitting rather than more alpha. {!Search.report.n_evaluated} therefore counts every trial in
    every generation, including the ones selection discarded — not the surviving population — and
    that number is what belongs in {!Overfitting.deflated_sharpe_ratio}'s [n_trials].

    Comparing a GA against another search on {i raw} Sharpe will always flatter whichever spent the
    larger budget. Compare at equal evaluation budget, on the deflated figure. There is a worked
    example in [test/optimization/test_genetic.ml] and in the optimization guide. *)

type config = {
  population : int;  (** ≥ 2 *)
  generations : int;  (** ≥ 0; total evaluations are [population * (generations + 1)] *)
  crossover_rate : float;  (** in [0, 1] *)
  mutation_rate : float;  (** per-gene probability, in [0, 1] *)
  elitism : int;
    (** at least 0 and strictly less than [population]; best-so-far cannot regress when ≥ 1 *)
  tournament_size : int;  (** in [1, population]; selection pressure *)
}

val default_config : config

type error =
  [ `Empty_space
  | `Bad_config of string
  ]

(** Run the search. Failed evaluations become failed trials scoring [neg_infinity] — they lose every
    tournament and are reported in [n_failed] — so one bad point cannot abort the run.

    [n_domains] is passed to the same pool {!Search} uses; results do not depend on it. *)
val optimize :
  space:Search_space.t ->
  objective:Objective.t ->
  eval:Search.eval ->
  config:config ->
  root_seed:int64 ->
  n_domains:int ->
  (Search.report, error) Stdlib.result

val error_to_string : error -> string
