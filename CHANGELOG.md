# Changelog

All notable changes to AlgoStream are documented here. The format follows
[Keep a Changelog](https://keepachangelog.com/en/1.1.0/) and this project
adheres to [Semantic Versioning](https://semver.org/spec/v2.0.0.html).

## [0.1.0] - 2026-08-15

First public release.

### Added

- **Event bus** — four-band priority queue, a dispatcher Domain fanning out to subscribers, an
  append-only `bin_prot` log and deterministic replay.
- **Data ingestion** — Binance and Coinbase WebSocket connectors behind a connection supervisor
  with circuit breaking, rate limiting, symbol interning and data-quality gates.
- **Normalization and time series** — canonical symbols, bar building and multi-series alignment.
- **Analytics** — rolling statistics, cointegration testing, hedge-ratio estimation and z-score
  computation for pairs.
- **Advanced models** — Ornstein-Uhlenbeck, Kalman filtering, GARCH and regime detection.
- **Strategy and backtest** — a single `Strategy.S` contract and a fill simulator with order-book
  depth, queue position, slippage and cost models.
- **Order and risk management** — routing, sizing, execution-quality measurement, VaR and limits.
- **Monte Carlo, optimization and performance** — path simulation, walk-forward analysis and
  return attribution.
- **Live runtime** — a paper-trading runner driving the same strategy code as the backtester
  against a live feed, with `test/runtime/test_parity.exe` asserting the two produce identical
  results from one fixture.
- **Telemetry and reporting** — metrics, health checks, alerting and report export.
- **HTTP API and dashboard** — a single Lwt scheduler serving a JSON API and an SSE dashboard.
- **Security** — bearer keys with scopes, `0600` keystore enforcement, and a hash-chained audit
  log with tamper detection.
- **Operations** — release and dev container images, a loopback-bound observability stack
  (Prometheus, Alertmanager, Grafana), Kubernetes manifests and a blue/green promotion script.
- **Documentation** — 24 guides, three architecture documents and a generated API reference.

### Notes

This is paper trading. There is no venue connectivity anywhere in the project — no exchange
credentials, no request signing, no trading endpoint. Fills are simulated against live quotes by
the same engine the backtester uses.

Performance figures are stated in the README alongside the machine and the command that produced
them. Targets that cannot be validated without a venue are marked as such where they appear,
rather than reported as results.

[0.1.0]: https://github.com/chizy7/AlgoStream/releases/tag/v0.1.0
