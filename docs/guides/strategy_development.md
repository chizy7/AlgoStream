# Strategy Development Tutorial

Writing a strategy, testing it against history, and running it live — using the same code for both.

That last part is the whole design. `lib/strategy/` depends on neither `backtest` nor `event_bus`;
its `dune` says so explicitly. A strategy is a pure decision function, and the two drivers —
`Backtest.Engine` offline and `Runtime.Instance` live — feed it the same `Event.t` and interpret the
same `Action.t list`. `test/runtime/test_parity.ml` asserts they produce identical fills, counters
and NAV from one fixture, which is what makes a backtest worth anything here.

Paper trading throughout. There is no venue connectivity in this project.

## The interface

```ocaml
module type S = sig
  type params
  type state

  val name : string
  val default_params : params
  val init : params -> state
  val on_event : state -> Context.t -> Event.t -> state * Action.t list
end
```

Two things about `on_event` are worth dwelling on.

**It returns actions rather than submitting them.** Nothing in a strategy places an order. It
returns intent, and risk gating, position sizing and routing happen outside — which is why the same
strategy can run against a simulator and a live feed without knowing which it is in.

**It is a pure function of `(state, context, event)`.** No clock reads, no RNG, no I/O. CI enforces
the first two: a lint bans `Time_utils.Clock` and `Random.self_init` under `lib/strategy/`. This is
not stylistic. A strategy that reads the wall clock produces different decisions on replay than it
did live, and every backtest you run afterwards is measuring the clock.

`Context.t` exposes market and portfolio state as accessor closures, so a live driver can back it
with processor snapshots without copying.

## A worked example

A minimum viable strategy: go long when price drops more than `threshold` below a rolling mean,
flatten when it recovers.

```ocaml
type params = { symbol : string; window : int; threshold : float }
type state  = { prices : float list; position : float }

let name = "mean_reversion_demo"
let default_params = { symbol = "BTCUSDT"; window = 20; threshold = 0.02 }
let init _ = { prices = []; position = 0.0 }

let on_event state ctx event =
  match event with
  | Event.Tick t when String.equal t.symbol default_params.symbol ->
    let prices = t.price :: (if List.length state.prices >= default_params.window
                             then List.filteri (fun i _ -> i < default_params.window - 1) state.prices
                             else state.prices) in
    let state = { state with prices } in
      if List.length prices < default_params.window then (state, [])
      else
        let mean = List.fold_left ( +. ) 0.0 prices /. float_of_int (List.length prices) in
        let deviation = (t.price -. mean) /. mean in
          if deviation < -.default_params.threshold && state.position <= 0.0 then
            ({ state with position = 1.0 },
             [ Action.Submit { symbol = t.symbol; side = Buy; quantity = 1.0 } ])
          else if deviation > 0.0 && state.position > 0.0 then
            ({ state with position = 0.0 },
             [ Action.Submit { symbol = t.symbol; side = Sell; quantity = 1.0 } ])
          else (state, [])
  | _ -> (state, [])
```

Three habits worth forming, all visible above:

- **Ignore what you do not handle.** `| _ -> (state, [])`. A strategy sees fills, order updates,
  bars and pair snapshots as well as ticks.
- **Filter by symbol.** A live runtime subscribes to everything the instance's config lists.
- **Keep state bounded.** The window truncation matters: a live strategy runs for weeks, and an
  unbounded accumulator is a slow leak that a short backtest will never show you.

## Testing it

Start offline. `Backtest.Engine` needs a data source and a cost model:

```bash
make fixture OUT=/tmp/fixture.log BARS=5000
dune exec bin/backtest.exe -- --log-file /tmp/fixture.log --strategy mean_reversion_demo
```

Then the check that actually matters:

```bash
dune exec test/runtime/test_parity.exe
```

Same strategy, same events, driven both ways. If they diverge, the cause is almost always
impurity — a clock read, a hash-order dependency, or state carried between instances.

## Running it live

```bash
dune exec bin/algostream.exe -- \
  --symbols BTCUSDT,ETHUSDT \
  --strategy pairs --y BTCUSDT --x ETHUSDT \
  --capital 100000 \
  --static site/
```

Then `http://127.0.0.1:8080/dashboard/`.

Every fill is simulated against live quotes by `Runtime.Paper_broker`, reusing the backtest cost
model and slippage. There is no venue connectivity anywhere in this project — no credentials, no
request signing, no trading endpoint — so a strategy cannot place a real order however it is
configured.

## Registering a strategy

1. Add the module under `lib/strategy/`.
2. Add it to `lib/strategy/dune`'s `modules` field.
3. Wire it into the daemon's strategy selection in `bin/algostream.ml`.
4. Give it a test under `test/strategy/`.

## Common mistakes

**Reading the clock.** CI will reject it. Use the event's own `timestamp_ns` — which is also the
only thing that behaves the same on replay.

**Assuming ordering across symbols.** Ticks for different symbols interleave arbitrarily. Anything
that needs alignment should use `Time_series.Processor` bars or a `Pair_snapshot`.

**Unbounded state.** See above.

**Treating a `Submit` as a fill.** It is intent. Risk limits may reject it, sizing may change the
quantity, and the fill arrives later as its own event. Update position on the fill, not on the
submission.

**Believing a backtest Sharpe.** The project's Sharpe and drawdown targets are recorded as
**unvalidated** for exactly this reason: a number produced by a strategy that has never traded
measures the backtest, not the strategy.
