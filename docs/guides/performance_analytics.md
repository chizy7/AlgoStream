# Performance Analytics Guide

`lib/performance` is the canonical home for risk-adjusted metrics. Six modules:

| Module              | Purpose                                                                    |
| ------------------- | -------------------------------------------------------------------------- |
| `Returns`           | equity curve → returns, and the annualization factor everything depends on |
| `Metrics`           | Sharpe, Sortino, Calmar, Omega, Martin, VaR/CVaR, tail ratio — one record  |
| `Drawdown_analysis` | drawdown _episodes_ with recovery times                                    |
| `Benchmark_compare` | alpha, beta, tracking error, information ratio, capture                    |
| `Attribution`       | grouped P&L contributions and the gross-to-net cost waterfall              |

Pure functions over plain arrays. It does not depend on `algostream.backtest` — metrics stay usable
against a live portfolio's fill history, and `Backtest.Result.to_perf_fills` adapts in the one
direction that keeps the dependency acyclic.

## The consolidation story

This is the reason the library exists in the form it does. The tree carries **four**
max-drawdown implementations and **three** Sharpe implementations across **three different
formulas**, two of them sharing a field name:

| Site                                                          | Sharpe formula                       | Annualized? | Risk-free? |
| ------------------------------------------------------------- | ------------------------------------ | ----------- | ---------- |
| `Portfolio.Risk_metrics.calculate_risk_metrics`               | `mean_return / volatility`           | no          | no         |
| `Portfolio.Portfolio_analytics.calculate_performance_summary` | `total_return / volatility`          | no          | no         |
| `Math_utils.FinancialMath.sharpe_ratio`                       | `(mean − rf) / stdev`                | no          | yes        |
| `Pair.Pair_analytics`                                         | `avg_trade_pnl / stdev_of_trade_pnl` | no          | no         |

The first two report their different answers in a field called `sharpe_ratio`. The fourth is not
return-based at all — it is a per-trade figure.

That fourth site was **found by `make metrics-dup-lint` on its first run**. The documentation before
that said "three max-drawdown and two Sharpe implementations"; the lint disagreed and was right.

Nothing was deleted. `Portfolio.Risk_metrics` is load-bearing for
`Risk_management.Var.Historical`, and the `Pair` functions, while dead, sit in a foundational module. The
resolution is: one canonical implementation here, the legacy sites documented as superseded, and two
durable guards —

- **`make metrics-dup-lint`** (also a CI step) fails if a new Sharpe/Sortino/Calmar/max-drawdown
  definition appears outside `lib/performance`, with an explicit allowlist naming each legacy site
  and why it is there.
- **`test/performance_analytics/test_consolidation.ml`** asserts that max-drawdown _agrees_ with
  `Portfolio.Risk_metrics`, and **pins the disagreement** between the two legacy Sharpes — so
  "fixing" one of them silently fails a test instead of quietly changing a number somebody relies
  on.

## Conventions

These are stated because they are exactly where implementations silently disagree:

- **Volatility**: sample standard deviation, `n−1` denominator.
- **Downside deviation**: **full-sample `n`** denominator — observations above the MAR contribute
  zero rather than being excluded. This is the standard Sortino convention and the single largest
  source of disagreement between tools. A test asserts the smaller (correct) figure against the
  exclude-upside alternative.
- **Annualization**: mean × periods-per-year, standard deviation × √periods-per-year, via
  `Returns.periods_per_year`. Assumes serially independent returns; for a strongly autocorrelated
  series the annualized volatility is understated and no Newey-West correction is applied.
- **Calendar**: 24/7 by default (365 days), correct for the crypto feeds this platform ingests. Pass
  `~days_per_year:252` and `~hours_per_day:6.5` for session-traded instruments.
- **Every ratio returns `0.0`**, never `nan` or `infinity`, when its denominator is zero. Which case
  produced the zero is recoverable from the component fields.
- **VaR and CVaR delegate** to `Risk_management.Var.compute ~method_:Historical`. There is no fourth
  VaR here, and a test asserts the delegation is exact.

## Drawdown episodes

`Drawdown.Tracker` gives running scalars for live gating;
`Portfolio.Risk_metrics.calculate_maximum_drawdown` gives one number. Neither can answer "how many
drawdowns, how deep, and how long did each take to recover" — which distinguishes a strategy with
one catastrophic 30% drawdown from one with ten shallow ones that recover in a day.

An episode runs peak → trough → recovery. The final episode may be unrecovered, in which case
`recovery_ns` is `None` — reported honestly rather than closed at the sample end, which would
understate the true recovery time.

```ocaml
let eps = Drawdown_analysis.episodes ~nav () in
Array.iter (fun e -> print_endline (Drawdown_analysis.episode_to_string e))
  (Drawdown_analysis.worst eps ~n:3)
```

`mean_recovery_ns` averages over **recovered episodes only**; folding in the unrecovered ones as
though they had recovered at the sample end would bias the figure downward.

## Attribution, and what it is not

**This is not Brinson attribution.** Brinson needs benchmark weights per group per period, a concept
this system has no notion of. What ships is grouped P&L contributions — by symbol, strategy, side,
liquidity, regime, holding period — plus a gross-to-net cost waterfall. For a single-strategy
statistical-arbitrage book that is the attribution that informs decisions; calling it Brinson would
be a misrepresentation.

`by_liquidity` is the one to read first on a high-turnover book: it answers whether the edge survives
paying the taker fee.

Financing is spread across fills pro rata by notional in `Result.to_perf_fills`. Financing accrues on
carried exposure, not on any one fill, so there is no correct per-fill attribution — the
approximation is called out rather than presented as measured.

## Event-time invariant

Nothing here reads a clock; time enters as `int64` nanoseconds on the NAV curve.
`make metrics-clock-lint` enforces it, and CI runs the same check.

## Tests + benchmarks

```bash
dune runtest test/performance_analytics   # 59 tests across 6 suites
make metrics-clock-lint && make metrics-dup-lint
make metrics-bench                        # Apple Silicon, 5,000-point curve:
                                          #   of_nav ~4.0 ms, drawdown episodes ~19 us,
                                          #   returns ~18 us, benchmark_compare ~128 us
```

`of_nav` is dominated by its two historical-VaR calls, and those by `Array.sort` — OCaml's
polymorphic sort boxes every element of a flat `float array`, costing ~0.9 ms per sort. This library
removed a redundant list conversion and a duplicate sort there (~1.5 ms → ~1.0 ms per VaR call); a
monomorphic float sort would recover most of the remainder and is recorded as a follow-up in
`Var.historical_var_es` rather than rushed in. The cost is bounded and known: the Monte Carlo path
that actually runs 10,000 times uses ~1,000-point series at ~0.75 ms each.

Degenerate inputs are tested explicitly, because that is where metric libraries produce `nan` and
poison a whole Monte Carlo batch: zero volatility, all-zero returns, an empty series, and a
monotonically rising curve (where Calmar divides by a zero drawdown) must all yield finite fields.

