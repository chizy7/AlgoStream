# Reporting Guide

Turning the analytics into something that leaves the process.

## The gap this fills

Everything numeric already existed. `Performance.Metrics` computes 27 risk-adjusted figures,
`Drawdown_analysis` extracts episodes with recovery times, `Attribution` decomposes P&L,
`Risk_management.Var` prices four VaR methods.

What was missing was any way to get them **out**. Every one of those layers exposes a `to_string`
aimed at a terminal — 48 such functions across the tree — and not one exposes rows. There was no
`to_json` anywhere, and the only CSV writers were two hand-rolled `Printf` loops in
`Backtest.Result`.

## A real bug it fixes

`Backtest.Result.write_blotter_csv` emitted `strategy_id` and `tag` with a bare `%s`. Both are
strategy-supplied free text — `tag` exists precisely so a fill can be traced back to the reason it
was placed — so a comma or a newline in either silently corrupted the file, shifting every later
column by one.

`Export.csv_escape` implements RFC 4180 quoting: a field containing a comma, a double quote, CR or
LF is wrapped in quotes with internal quotes doubled. `Result`'s writers now use the same rule.

Non-finite floats render as an **empty cell**, not `nan`: a spreadsheet treats `nan` as text and it
poisons the whole column's type inference.

## Reports

| Name | Contents |
|---|---|
| `performance` | Every metric from a NAV curve, via `Metrics.to_assoc` |
| `drawdowns` | Episodes: peak, trough, recovery, depth, duration |
| `risk` | Exposure, VaR/ES, limit breaches, circuit-breaker state |
| `positions` | Everything currently held, per instance |
| `fills` | Execution view: price, commission, maker/taker |
| `audit` | The audit trail — see below |
| `summary` | The runtime's flattened metrics |

Fetch any of them as CSV or JSON:

```bash
curl 'localhost:8080/api/reports/fills?format=csv'
```

## Not xlsx

Excel export is **not implemented**. A real `.xlsx` is a ZIP container of OOXML parts, which is a
meaningful amount of machinery for a format Excel opens from CSV anyway. Requesting it returns a
`400` that says so, rather than silently handing back CSV under a misleading name.

## "Regulatory reporting"

A stated goal was "regulatory reporting capabilities". What ships is `audit`: a complete,
timestamped record of every **simulated** order and fill, carrying the identifiers needed to
reconcile an order end to end, plus an explicit `execution_mode` column reading `paper`.

It is **not** certified against MiFID II RTS 22, CAT, EMIR or any other regime, and nothing here
should be filed with anyone. Calling an audit export "regulatory reporting" without that sentence
would be the kind of claim this project takes care not to make.

## Known gaps / follow-ups

- **Portfolio-level performance needs a NAV curve the runtime does not retain.** Each instance keeps
  its own bounded ring; there is no combined, durable series, so `performance` and `drawdowns` over
  the live runtime report on an empty curve rather than inventing data. Run them against a backtest
  `Result` instead.
- **No scheduled generation.** Reports are pulled; nothing writes them on a timer.
- **No attribution endpoint.** `Report.attribution` exists and works, but the daemon has no fills
  array in the shape `Attribution` wants without a conversion pass.

## Source map

| Module | Path |
|---|---|
| CSV/JSON writers, quoting | `lib/reporting/export.{ml,mli}` |
| Report assembly | `lib/reporting/report.{ml,mli}` |
| Escaping fix in the backtest writer | `lib/backtest/result.ml` |
| Tests | `test/reporting/test_export.ml` |

## Scope and limitations

Performance, risk and execution reports generate and export as CSV and JSON.

**Regulatory reporting ships as an uncertified audit trail** — a defensible record of activity, not
a compliance claim against any specific regime. `.xlsx` export is not implemented; CSV opens
natively in Excel.
