# Data Normalization & Quality Guide

`lib/normalization` makes the multi-exchange feeds usable from strategy code: canonical
`Symbol.t`, asset-aware validation, cross-feed basis tracking, per-feed health, lineage paths,
and a corporate-actions framework. Sits alongside `lib/time_series` and `lib/analytics`, all
consuming the same bus stream.

## Canonical symbols

Different exchanges, different conventions. `Symbol.parse` resolves them to a common shape:

```ocaml
let s = Symbol.parse ~exchange:"binance" ~raw:"BTCUSDT" |> Option.get in
(* s = { base = "BTC"; quote = "USDT"; asset_class = Crypto } *)
Symbol.to_canonical s   (* "BTC/USDT" *)
```

**USDT and USD are intentionally distinct.** Binance "BTCUSDT" against Coinbase "BTC-USD" is a
USDT-vs-USD basis, not a Binance-vs-Coinbase inconsistency. The cross-feed basis tracker
surfaces the spread as a metric.

Static tables ship for Binance and Coinbase majors; tests register new mappings via
`Symbol.register`.

## Asset-aware validation

Extends the ingestion-side `Data_quality` verdicts:

```ocaml
match Validator.check_tick asset ~price ~size with
| None -> publish_tick ()
| Some (Tick_size_violation _) -> drop_with_warning ()
| Some (Min_trade_size_violation _) -> drop_with_warning ()
```

`Asset.tick_size` is a `float`, so binary-representation problems are real (a `0.01` tick is
not exactly representable). The validator uses a half-tick tolerance:
`|price/tick_size - round(price/tick_size)| < 1e-6`.

## Cross-feed basis (metric, not verdict)

For two feeds reporting the *same canonical symbol*, track
`basis = (price_a - price_b) / mid` over a rolling window. Anomalies surface as
`|current_z| > k`, not as fixed-threshold violations.

```ocaml
let cf = Cross_feed.create
           ~canonical:{ base = "BTC"; quote = "USD"; asset_class = Crypto }
           ~feed_a:"coinbase" ~feed_b:"kraken" () in
Cross_feed.update cf ~ts_ns ~price_a ~price_b;
let stats = Cross_feed.stats cf in
if abs_float stats.current_z > 3.0 then
  Logs.warn (fun m -> m "anomalous basis on %s: z=%.2f" ...)
```

This is **not** a `Data_quality` verdict — it's an analytics signal. Strategies opt in.

## Feed health

Per-`Event.t.source` latency + freshness tracker. Hashtable keyed by source string with
configurable cap (default 64) and LRU eviction — bounds DoS via spoofed sources in third-party
replay logs.

```ocaml
let fh = Feed_health.create () in
Feed_health.observe fh ~source:"binance" ~ts_ns ~latency_ns;
Feed_health.record_gap fh ~source:"binance";
match Feed_health.per_source fh ~source:"binance" with
| Some s -> Printf.printf "ticks=%Ld gaps=%Ld avg_lat=%Ldns\n" s.ticks s.gaps s.avg_latency_ns
| None -> ()
```

## Data breaks (corporate actions)

Generalized variant covering crypto + equities:

```ocaml
type t =
  | Split of { ratio : float }
  | Dividend of { amount : float; currency : string }
  | Symbol_change of { from_ : string; to_ : string }
  | Fork of { parent : string; children : (string * float) list }
  | Halt of { until_ns : int64 }
```

Apply returns a verdict matching the action's effect on a single tick:

```ocaml
match Data_break.apply entries tick with
| Pass -> publish tick
| Drop -> ()                              (* halt window *)
| Rewrite t' -> publish t'                (* split: scale price/volume; symbol_change: rename *)
| Emit_synthetic ts -> List.iter publish ts (* fork: emit child ticks *)
```

JSON config per asset:

```json
[
  { "effective_at_ns": 1654041600000000000, "kind": "halt", "until_ns": 1654128000000000000, "source": "binance_announcement" },
  { "effective_at_ns": 1700000000000000000, "kind": "symbol_change", "from": "MIM", "to": "USDT", "source": "manual" }
]
```

v1 wires `Symbol_change` and `Halt` for crypto. `Split` / `Dividend` / `Fork` are populated for
equities + future crypto fork events.

## Lineage

A lightweight transformation-chain encoded into the existing `Event.t.source` field as
`/`-separated tokens. No schema bump.

```ocaml
let parts = Lineage.of_source ev.source in
(* ["binance"; "normalized"; "v1"] *)

match Lineage.push "binance" "normalized" with
| Some s -> { ev with source = s }
| None -> (* invalid format / overlong; fail-closed *)
```

Format: `^[a-z0-9_]+(/[a-z0-9_]+)*$`, max 64 chars. Enforced by `Lineage.is_valid`.

## Source map

| Module | Path |
|---|---|
| Canonical symbol | `lib/normalization/symbol.{ml,mli}` |
| Validator | `lib/normalization/validator.{ml,mli}` |
| Cross-feed basis | `lib/normalization/cross_feed.{ml,mli}` |
| Feed health | `lib/normalization/feed_health.{ml,mli}` |
| Lineage | `lib/normalization/lineage.{ml,mli}` |
| Corporate actions | `lib/normalization/data_break.{ml,mli}` |
| Tests | `test/normalization/` |
