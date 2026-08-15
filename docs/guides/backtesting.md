# Backtesting Guide

`lib/strategy` and `lib/backtest` close the loop the strategy layer left open. That layer produced every
ingredient of a statistical-arbitrage decision — cointegration, spread z-scores, hedge ratios,
GARCH, VaR — but nothing that _decided_ anything: `Pairs.Snapshot.signal` was computed, published,
and read by exactly one caller, `Snapshot.to_string`, which printed it.

Two libraries, eleven modules:

| Layer              | Modules                                                           |
| ------------------ | ----------------------------------------------------------------- |
| Strategy contract  | `Side`, `Event`, `Action`, `Context`, `Strategy`                  |
| Reference strategy | `Pairs_mean_reversion`                                            |
| Market simulation  | `Data_source`, `Market_view`, `Slippage`, `Latency`, `Cost_model` |
| Execution          | `Fill_engine`                                                     |
| Output             | `Result`, `Engine`                                                |

`lib/strategy` depends on neither `algostream.backtest` nor
`algostream.infrastructure.event_bus`, and a test asserts that. A future live runner can therefore
implement `Strategy.S` without linking the fill simulator.

## Reuse stance

Most of the market simulation is wiring, not new modelling:

| Need                      | Where it came from                                                 |
| ------------------------- | ------------------------------------------------------------------ |
| Order-book depth walk     | `Order_management.Book_impact.estimate_from_book` |
| Permanent market impact   | `Book_impact.permanent_impact`, Almgren square-root |
| Venue fees by volume tier | `Venue.effective_fee_bps` |
| Execution latency         | `Venue.base_latency_us` |
| Post-trade TCA            | `Order_management.Execution_quality.analyze` |
| Legal order transitions   | `Order_state.can_transition` |
| Pre-trade risk gate       | `Risk_limits.pre_trade_check` |
| Portfolio accounting      | `Domain.Portfolio`, now with `?ts` for event time                  |

Genuinely new: the strategy contract, queue-position maker fills, TIF enforcement, stop and iceberg
triggers, the latency delay queue, and the engine loop itself.

## The strategy contract

`on_event` **returns** actions rather than invoking a submit callback. Three things follow: a
strategy is testable as a pure function, order-id assignment and risk gating stay in the engine, and
the same `Strategy.S` can be driven by a backtest or a live runner.

```ocaml
val on_event : state -> Context.t -> Event.t -> Action.t list
```

Rules an implementation must honour — contract, not style:

- **No clocks.** Read time from `ctx.ts_ns`. `make strategy-clock-lint` and CI both enforce it.
- **No I/O, no Domains, no bus.** `on_event` runs inside the engine's inner loop.
- **Idempotence.** The classifier repeats `Long_spread` for as long as the z-score sits past the
  band — many ticks. Track what you have acted on, or you will submit an order per tick.

Every tunable is a `float` reachable through `params_of_assoc` / `params_to_assoc`. That pair is how
`algostream.optimization` traverses the space without knowing the concrete `params` type; a
parameter not reachable that way is one the optimizer cannot tune.

## Step ordering

Per market record, in this order. The ordering is contract — changing it changes results:

1. advance the event clock; drop and count out-of-order records
2. update `Market_view`; feed bar builders and per-pair state
3. release inbound messages whose delivery time has arrived (fills, order updates, timers)
4. release outbound orders that have now reached the venue
5. run one `Fill_engine` pass; book each fill into the portfolio and blotter
6. deliver the market event to the strategy; collect its actions
7. gate actions against risk limits, assign order ids, admit with outbound latency
8. mark to market, accrue financing, sample the equity curve

A fill is booked into the portfolio **before** the strategy is told about it. The portfolio is the
venue's view; the strategy's view is delayed by inbound latency. That asymmetry is real, and it is
what makes a latency-sensitive strategy behave differently here than in a naive simulator.

## Maker fills and queue position

Passive fills use an explicit queue. When a resting limit order arrives at the venue its
`queue_ahead` is seeded from `Order_book.depth_at_price`, and every subsequent tape print at or
through that price drains it. Filling begins only once it reaches zero.

The approximation is specific and documented: `depth_at_price` is cumulative _at or better_, so it
counts better-priced orders that are not literally in the queue. Those fill first regardless, so
the estimate errs toward making maker fills **harder**, not easier. What it cannot capture is
order-by-order priority within a level, which needs L3 data the ingestion layer does not collect.

An iceberg that refreshes a slice goes to the **back** of the queue — `queue_ahead` is reseeded from
current depth. That is real venue behaviour and the main reason naive iceberg simulation overstates
fill rates.

Three models, in decreasing fidelity:

| `maker_fill`     | Behaviour                                      | Use                                        |
| ---------------- | ---------------------------------------------- | ------------------------------------------ |
| `Queue_position` | drains `queue_ahead` on tape prints            | the default                                |
| `Touch_cross`    | fills when the market trades through the price | cheaper, adequate when not queue-sensitive |
| `Optimistic`     | fills the moment the touch arrives             | an upper bound, for bracketing only        |

## Costs, slippage and latency

`Cost_model` is stateful because fee tiers are volume-dependent: it accumulates realized notional
and rolls down the venue's ladder as the backtest trades. A strategy that starts retail and works
down to the top tier sees its costs fall, which is what matters when asking whether an edge survives
at achievable volume.

`Slippage.Regime_scaled` is the "slippage modeling _with market conditions_" requirement: the same
base model, multiplied by a factor keyed on the prevailing `Analytics.Regime.t` (Crisis ×3.0,
Volatile ×1.8, Trending ×1.2, Calm ×1.0 by default — a defensible shape, not a calibrated result).
A strategy backtested only against calm-regime slippage looks far better than it trades, because the
moments it most wants to transact are exactly when spreads widen and depth evaporates.

## Worked example

The fixture generator writes a two-leg log whose legs share a common factor and differ by a
mean-reverting spread, so the pair is genuinely cointegrated. No network, no recorded session, fully
deterministic:

```bash
make fixture OUT=/tmp/pair.log BARS=3000
make backtest LOG=/tmp/pair.log MC=2000
```

Real output from that command:

```
pairs_mean_reversion (seed=42 run=0)
  events=6000 dropped=0 actions=16 submitted=16 rejected=0
  fills=16 (maker=0 taker=16) cancelled=0 expired=0 fok=0 ioc=0 stops=0
  unfilled_qty=0 commission=79.95 financing=0.00
  NAV 100000.00 -> 99878.25 (-0.12%) over 3001 equity points

drawdown episodes (1, worst 3):
  #0 depth=0.12% decline=1.80d recovery=unrecovered underwater=1.97d

strategy diagnostics:
  signals                808
  entries                4
  exits                  0
  skipped_screen         5184
  skipped_idempotent     796
  forced_flat            4
```

Read the diagnostics before the P&L. `exits = 0` with `forced_flat = 4` says every position was
closed because the pair failed its cointegration screen, not because the spread reverted — the
strategy never actually completed a mean-reversion trade on this fixture. `skipped_idempotent = 796`
shows the idempotence guard suppressing 796 duplicate signals that would otherwise have become 796
orders. The −0.12% is 79.95 of commission on 16 taker fills against no realized edge, which is the
correct outcome for these parameters on this data, not a bug.

That is the point of the diagnostics: a backtest that loses money for a _legible_ reason is more
useful than one that makes money for an illegible one.

## Event-time invariant

`lib/strategy` and `lib/backtest` never read a clock. CI enforces a stricter pattern for these two
libraries than for the layers below: `Timestamp.now` is banned alongside `Clock.now_*` and
`Unix.gettimeofday`, because the domain mutators now accept `?ts` and the engine must always supply
it. Locally: `make bt-clock-lint`, `make strategy-clock-lint`, or `make determinism-lint` for all of them.

The engine carries its own `int64` event clock. Every timestamp in `Result.t` comes from it. The
`Timestamp.t` fields on `Portfolio` / `Position` / `Trade` are advisory metadata, populated via
`?ts` — no analytics path reads them, which is why the ~240 ns quantization of `Timestamp.of_ns`
cannot affect a reported number.

Verified end to end: two runs over the same log produce byte-identical equity and blotter CSVs.

```bash
dune exec bin/backtest.exe -- --log /tmp/pair.log --equity-csv /tmp/a.csv
dune exec bin/backtest.exe -- --log /tmp/pair.log --equity-csv /tmp/b.csv
diff /tmp/a.csv /tmp/b.csv        # empty
```

## Tests + benchmarks

```bash
dune runtest test/strategy      # 32 tests across 4 suites
dune runtest test/backtest      # 27 tests across 4 suites
make bt-clock-lint && make strategy-clock-lint
make bt-bench                   # Apple Silicon: ~840k ev/s frictionless,
                                # ~865k ev/s with spread + fees,
                                # ~920k ev/s book-walk over a 5-level ladder
```

The fill-engine tests assert hand-computed outcomes: a market buy across three ask levels
(10@100, 10@101, 10@102) taking 25 units must pay exactly 100.8; a 30-lot resting bid behind 100 of
depth fills nothing on a 60-lot print and exactly 20 on the second. The determinism suite compares
every `Timestamp` on the final portfolio across two runs — that is the regression test for the `?ts`
work, and it fails if anyone drops a `~ts` anywhere in the fill-to-portfolio path.

The bench is registered in `.github/workflows/benchmark.yml` and posts to gh-pages.

