# Monte Carlo Guide

`lib/rng`, `lib/stochastic` and `lib/montecarlo` answer one question: is this backtest result
distinguishable from luck?

| Layer     | Modules                                       |
| --------- | --------------------------------------------- |
| Generator | `Rng` (own library, zero deps)                |
| Sampling  | `Variate`, `Cholesky`, `Resample`, `Quantile` |
| Paths     | `Path`, `Regime_sim`, `Stress`, `Generator`   |
| Execution | `Pool`, `Engine`                              |

## Reuse stance

`Ornstein_uhlenbeck.simulate`, `Garch11`, `Distribution`, `Analytics.Regime` and the whole backtest
engine already existed. New here: the generator, the samplers, the bootstrap family, the regime
_sampler_ (the existing `Regime` is a detector with no transition model), the worker pool, and the
GARCH path sampler — `Garch11.forecast` returns a deterministic σ² sequence and does not simulate.

## Why the RNG was replaced

`Math_utils.FastRandom` is unusable for Monte Carlo, for three separate reasons:

```ocaml
let create_xorshift seed =
  { x = Int64.of_int seed; y = 362436069L; z = 521288629L; w = 88675123L }
```

- **Only `x` is seeded.** `y`, `z` and `w` are shared constants, so seeds `1 .. 10_000` — precisely
  what a simulation batch uses — produce heavily correlated streams.
- **`uniform_float` can return exactly `0.0`,** and `normal_sample` takes `log u1` with no clamp:
  `-inf`, then `nan`, silently poisoning a path.
- **`seed = 0`** gives a partially-zero xorshift state.

`lib/rng` is SplitMix64 seed expansion into xoshiro256++. It is its own library with zero
dependencies, because `advanced_models` depends on it (for the OU path sampler) while `stochastic`
depends on both — putting `Rng` alongside the samplers would have closed a cycle.

`test/rng/test_substream.ml` is the direct regression: across 64 adjacent index pairs, the maximum
absolute correlation must stay under 0.10. The old construction fails that catastrophically.

**Conformance is checked, not assumed.** `test_reference_vectors.ml` pins SplitMix64 against its
published seed-0 outputs, derives one xoshiro value entirely by hand
(`rotl(1+4, 23) + 1 = 0x2800001`), and then checks `Rng.create` and `Rng.substream` end to end
against an independently written implementation of the same spec. An earlier draft of that file
asserted a remembered output table and failed — which is why the vectors are now derived rather than
recalled.

## The determinism contract

```ocaml
val substream : root_seed:int64 -> index:int -> t
```

`substream` is a **pure function of its arguments**: it does not depend on call order, on any
generator having been drawn from, or on which Domain calls it. Run _k_ of a batch therefore draws
the same numbers no matter how many cores execute the batch.

Each run takes two disjoint substreams — `2i` for data and `2i+1` for execution. Keeping them
separate is common-random-numbers discipline: changing the latency model must not shift the price
path, or an A/B comparison drowns in path noise instead of measuring the change.

`Pool.map` completes the guarantee. Work is claimed from an atomic cursor and written to slot `i` of
a pre-allocated array — never appended in completion order — and an exception surfaces the _lowest_
failing index. `test/montecarlo/test_pool.ml` asserts bit-identical output at 1, 2, 4 and 8 Domains,
including under deliberately unequal per-item cost.

## Two modes

"10,000+ runs" and "path-dependent scenario generation" cost very differently, so both ship and both
numbers are published rather than quoting the cheap one.

| Mode                     | Resamples                       | Cost                        | Captures                     |
| ------------------------ | ------------------------------- | --------------------------- | ---------------------------- |
| Path-level (`run_paths`) | the realized return series      | ~1,350 runs/s single-domain | is this curve luck?          |
| Engine-level (`run`)     | a synthetic market, full replay | ~1 s/run                    | stops, sizing, impact, fills |

Only engine-level involves the fill model. Path-level is the right tool for "is this equity curve
distinguishable from noise", and it is what makes 10,000 runs routine.

## Bootstrap: pick the right variant

| Variant          | Preserves                                      | Use when                        |
| ---------------- | ---------------------------------------------- | ------------------------------- |
| `iid`            | nothing                                        | the series really is iid        |
| `moving_block`   | dependence up to block length                  | rarely — under-samples the ends |
| `circular_block` | same, every observation equally likely         | the usual default               |
| `stationary`     | same, and the resample is genuinely stationary | Politis-Romano; preferred       |

The variant matters less than the block length. `rule_of_thumb ~n` gives the conventional `n^(1/3)`.
The automatic Politis-White selector is deliberately absent: it needs a flat-top-kernel spectral
density estimate that is not worth hand-rolling to a defensible standard, and a wrong automatic
answer is worse than an explicit rule of thumb.

**`joint_index` is the one that matters for pairs.** Bootstrapping each leg independently destroys
the cointegration the strategy exists to trade, so the resampled world contains no tradable
relationship and the Monte Carlo faithfully reports a strategy that cannot work. Resample the shared
_time index_ and apply it to every series. The test measures exactly this: source correlation 0.9+,
preserved above 0.85 by `joint_index`, destroyed to under 0.2 by independent resampling.

## Regime simulation, precisely

`Analytics.Regime` is a detector: threshold rules with dwell hysteresis that label a series it is
shown. `Regime_sim` adds the missing generative half — label a historical series by driving
`Per_symbol` headlessly, count the transitions, and sample the resulting chain.

**What this is not:** a hidden Markov model. There is no Baum-Welch, no EM, no state uncertainty —
the states are taken as observed, because the detector observed them. The detector's threshold bias
is inherited wholesale. What it _does_ capture, and an iid bootstrap cannot, is that calm periods
cluster, crises are sticky, and the transition between them is abrupt.

`stationary_distribution` iterates from the chain's own `initial` rather than from uniform. A fitted
chain is usually reducible — a regime the detector never labelled ends up with an absorbing
self-loop from the smoothing — and a uniform start parks probability in states the process can never
reach. That disagreement between the analytic figure and the simulated occupancy is what the test
caught.

## Confidence intervals

Everything in `Quantile` sorts the full sample. **Do not use
`Math_utils.Statistics.create_percentile_tracker`**: it is reservoir-sampled (approximate) _and_
seeded with `Random.State.make_self_init ()` (irreproducible). Both properties disqualify it, and
`make rng-lint` enforces the ban.

Working in empirical quantiles also sidesteps the codebase-wide "no more than two significant
figures" caveat on `Distribution` — a percentile interval never inverts a CDF.

`mc_standard_error` is what makes a 99% interval honest. At 10,000 runs the 99% level rests on ~100
tail observations, so it is materially less certain than the 95% level, and the summary prints how
much:

```
  sharpe   mean=-46.95  p05=-60.28  p50=-47.20  p95=-32.16  ci95=[-63.30, -28.85]  mc_se(p05)=0.368
```

## Scaling, measured

`mc-bench` publishes the _measured_ speedup rather than claiming linearity:

```
mc.path_level: domains=1 runs=4000 elapsed=2988ms 1338 runs/s speedup=1.00x
mc.path_level: domains=2 runs=4000 elapsed=1601ms 2498 runs/s speedup=1.87x
mc.path_level: domains=4 runs=4000 elapsed=938ms  4264 runs/s speedup=3.19x
mc.path_level: domains=8 runs=4000 elapsed=708ms  5647 runs/s speedup=4.22x
```

4.2× on 8 cores, matching the 4–6× the `Pool` documentation predicts. OCaml 5 has a shared heap and
the metric pipeline allocates, so this is GC-bound before it is core-bound. 10,000 path-level runs
is roughly two seconds.

## Stress scenarios

The presets are **stylized, not replays**. `black_monday_1987` applies a gap and volatility
multiplier of roughly the magnitude that day is remembered for; it is not a tick replay, and this
system has no such data. Round numbers, two significant figures, shaped what-ifs.

When the sample is long enough, `Stress.conditional` is strictly preferable: it bootstraps from the
worst windows the instrument _actually_ experienced, so the magnitudes are empirical rather than
invented. Reach for the presets only when you need a shock more extreme than your history contains.

## Event-time invariant

None of these layers reads a clock; `make mc-clock-lint`, `make sto-clock-lint` and `make
rng-clock-lint` enforce it, and CI runs the same checks with a call-shaped pattern. The one wall-
clock read in the whole subsystem is the `wall_ns` telemetry field in the bench, which no assertion
touches.

## Tests + benchmarks

```bash
dune runtest test/rng           # 23 tests: conformance, substream independence, determinism
dune runtest test/stochastic    # 57 tests across 5 suites
dune runtest test/montecarlo    # 26 tests across 4 suites
make sto-bench                  # Apple Silicon: uniform ~38M draws/s, normal ~13.6M draws/s
make mc-bench                   # see the speedup table above
make determinism-lint
```

Property tests rather than pinned numbers where possible: `Variate.normal` passes KS against
`Distribution.Normal.cdf` and Jarque-Bera; the GARCH sampler must show Ljung-Box autocorrelation in
_squared_ returns but not raw ones (volatility clustering, the property iid bootstrap destroys);
`multivariate_gbm` must recover a 0.70 input correlation within ±0.02.

