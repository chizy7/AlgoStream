# Strategy Optimization Guide

`lib/optimization` searches a strategy's parameter space and then tries hard to talk you out of
believing the result. Eight modules:

| Layer            | Modules                            |
| ---------------- | ---------------------------------- |
| Space and target | `Search_space`, `Objective`        |
| Search           | `Search`, `Genetic`                |
| Validation       | `Walk_forward`, `Cross_validation` |
| Scepticism       | `Overfitting`                      |
| Combination      | `Ensemble`                         |

## Reuse stance

`Advanced_models.Nelder_mead` provides local refinement, `Distribution.Normal` the CDF and quantile
behind the deflated Sharpe ratio, `Stochastic.Cholesky` the solve behind minimum-variance weights,
and `Montecarlo.Pool` the parallel evaluation. New here: the search space representation, the
validation schemes, and the overfitting statistics.

Every searcher takes an `eval` callback rather than a strategy and a data source. Search algorithms
stay independent of what is being evaluated — walk-forward passes an `eval` closed over one fold,
cross-validation over one split, and the unit tests pass a closed-form quadratic with a known
optimum, which is why the search tests run in milliseconds and a failure is unambiguously the
searcher's fault.

## The parameter space

A point is a `(string * float) list` — the flat representation `Strategy.S.params_of_assoc`
consumes. Keeping it flat is what lets the optimizer traverse any strategy's parameters without
knowing the concrete `params` type, and without existentials or GADTs.

`grid_points` returns `` `Too_large n `` rather than sampling a subset when the Cartesian product
exceeds the budget. A silently truncated sweep reported as exhaustive is worse than a refusal.

**`stratified_points` is Latin hypercube, not Sobol.** An earlier draft used a Sobol sequence, and
its direction-number table was misaligned — dimension _k_ needs _s = k_ initial values and several
rows had one. A wrong table degrades coverage _silently_: the sequence still looks valid, it just
stops being low-discrepancy. LHS gives the same "better than random for the same budget" benefit and
is correct by construction: each axis is cut into _n_ strata and every stratum receives exactly one
sample, which `test_stratified_covers_every_stratum` checks directly.

What LHS buys is stated precisely, because a first version of the test asserted more than it
delivers and failed: **exact marginal coverage**, not guaranteed joint coverage. On a discrete grid
whose optimum sits at one specific cell it is not reliably better than random search at finding that
cell. The advantage shows on smooth objectives and grows with dimension.

## Validation

Naive k-fold on financial returns leaks. Observations near a fold boundary are serially correlated
with those on the other side, so a model fitted on one has partial knowledge of the other and the
out-of-sample Sharpe comes back inflated. Two corrections, both implemented:

- **Purge** — drop training observations whose evaluation window overlaps the test fold.
- **Embargo** — additionally drop training observations for a period _after_ the test fold, since
  the test period's information bleeds forward.

`is_leak_free` makes the property checkable, and the test suite asserts it on every split of both
schemes. A second test confirms the embargo genuinely shrinks the training set — a no-op embargo
would pass the leak check trivially.

`Combinatorial_purged` (CPCV) goes further: every combination of _k_ test groups out of _n_ yields a
distinct out-of-sample path, so you get a **distribution** of out-of-sample Sharpe rather than a
point estimate. C(6,2) = 15 paths, C(10,3) = 120. Combined with `Quantile.percentile_interval` that
is an honest confidence interval on out-of-sample performance with no new dependencies.

## Walk-forward

**The headline number is the stitched out-of-sample curve, not the average of per-fold Sharpes.**
Averaging per-fold ratios hides compounding: three consecutive losing folds average to the same
number as three scattered ones, but the drawdown they produce is entirely different.

For the same reason each fold's test period begins from the _previous_ fold's terminal NAV. Resetting
equity at every boundary would silently erase every drawdown that spans one. The test plants three
folds each losing 10% and asserts the stitched curve compounds to 0.9³ rather than returning to par.

`param_stability` reports the coefficient of variation of each parameter across folds. A parameter
that jumps around between folds was never really estimated — it was fitted to noise.

## Scepticism

The most useful module here, and among the cheapest. An optimizer's job description — "find the
parameters that scored best on this history" — is also a precise description of how to overfit.
Search 500 configurations and the best Sharpe you find is drawn from the _maximum_ of 500 draws.

| Function                              | Question it answers                                          |
| ------------------------------------- | ------------------------------------------------------------ |
| `expected_max_sharpe`                 | what would the best of _n_ pure-noise trials have scored?    |
| `deflated_sharpe_ratio`               | probability the observed Sharpe is not just selection bias   |
| `probability_of_backtest_overfitting` | is the selection procedure worse than random?                |
| `minimum_backtest_length`             | is this sample long enough to support the search at all?     |
| `sharpe_standard_error`               | how uncertain is a Sharpe from non-normal returns? (Lo 2002) |

Read the deflated Sharpe as a p-value in reverse: 0.95 means a 5% chance this is selection bias.
Below ~0.90, do not trade it. A test asserts it sits near 0.5 exactly at the expected maximum —
where, by construction, the result is no evidence at all.

`Walk_forward` charges the deflated Sharpe against the **total** trials across all folds, because
the search saw the whole sample; that is the multiple-testing budget that actually applies.

A PBO above 0.5 means the selection procedure is worse than picking at random.

## The genetic algorithm, and when not to use it

`Genetic.optimize` runs real-valued chromosomes over a `Search_space.t`: tournament selection,
BLX-α crossover, per-dimension Gaussian mutation, and elitism. It is reproducible from `root_seed`
alone — each generation draws its own substream, so the result does not depend on how the pool
schedules evaluations or how many domains it uses.

**It is not the default, and for most work it is the wrong tool.** Over a smooth, largely unimodal
surface, `Search.stratified` followed by `Search.nelder_mead_refine` finds the same optimum more
cheaply and deterministically. Reach for the GA in one specific case: `nelder_mead_refine` refuses
more than four continuous dimensions, so on the reference strategy's eight parameters the
alternative is global sampling with _no local refinement at all_. A GA refines at any
dimensionality.

### Compare at equal budget, on the deflated figure

What a GA reliably adds is more evaluations, and on a fixed history more evaluations is more
overfitting rather than more alpha. `report.n_evaluated` therefore counts **every trial in every
generation**, including the ones selection discarded — not the surviving population — and that
number is what belongs in `deflated_sharpe_ratio`'s `n_trials`.

Comparing a GA against another search on _raw_ Sharpe will always flatter whichever spent the
larger budget. The comparison that means something holds the budget fixed and scores the deflated
figure:

```ocaml
let budget = cfg.Genetic.population * (cfg.Genetic.generations + 1) in
let ga  = Genetic.optimize ~space ~objective ~eval ~config:cfg ~root_seed ~n_domains in
let lhs = Search.stratified ~space ~objective ~eval ~n_domains ~n:budget ~root_seed in
(* Both are then charged the same n_trials in deflated_sharpe_ratio. *)
```

`test/optimization/test_genetic.ml` runs exactly this and asserts both arms report the same
`n_evaluated`, so neither can quote a raw best.

### Two things the reference space does badly

Both waste evaluations, both affect `stratified` identically, and neither is visible in the box
bounds:

- `use_limit_orders` is thresholded at 0.5 into a boolean, so the surface is a **step** along that
  axis rather than anything a blend operator can descend.
- `min_half_life_bars` and `max_half_life_bars` carry an **ordering constraint** that box bounds
  cannot express, so points with the two inverted are sampled and scored as failures.

These are properties of the representation, not of the search.

## Ensembles

**Rolling weights, not full-sample weights.** Fitting minimum-variance weights on the whole sample
and reporting the resulting Sharpe is in-sample optimization wearing a diversification costume — the
covariance you optimized against is the one you measured. `rolling_combine` re-estimates on a
trailing window and applies the weights forward. `combine` exists for the one-shot case and says so
in its own documentation.

`Min_variance` solves `Σw = 1` by Cholesky forward/back substitution, then clips to long-only and
renormalizes. **The clip makes it approximate**: an exact long-only minimum-variance portfolio is a
quadratic program, and adding a QP solver for one function was not worth a new dependency. When the
unconstrained solution is already non-negative — common for weakly correlated members — the clip
does nothing and the answer is exact. A test checks it against the closed form on a diagonal
covariance.

`incremental_sharpe` is the number to look at: the change in combined Sharpe from dropping each
member. A member with a positive standalone Sharpe can still be subtracting value.

## Event-time invariant

Nothing here reads a clock. `make opt-clock-lint` enforces it; searches are reproducible from
`root_seed` alone, and evaluation runs through `Montecarlo.Pool`, so a report does not depend on how
many Domains ran it.

## Tests + benchmarks

```bash
dune runtest test/optimization   # 44 tests across 7 suites
make opt-clock-lint
make determinism-lint
```

The suite tests properties rather than pinned numbers: the deflated Sharpe must fall monotonically in
trial count, purged splits must contain no train/test overlap under any embargo, CPCV must produce
exactly C(n,k) splits, stitched walk-forward equity must compound rather than reset, and
minimum-variance weights must match the analytic inverse-variance solution on a diagonal covariance.

## Scope and limitations

**A GA is available but is not the default** — see above for when it earns its place and why its
evaluation budget must be carried into the deflated Sharpe correction. `Pairs.Cointegration.Johansen`
remains an honest `Not_supported_in_v1` stub.

Everything in the layer is live: walk-forward analysis (rolling and anchored), purged k-fold
and CPCV cross-validation, deflated Sharpe / PBO / minimum backtest length, regime-labelled
robustness testing, and ensemble construction.
