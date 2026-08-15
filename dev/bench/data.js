window.BENCHMARK_DATA = {
  "lastUpdate": 1786830882381,
  "repoUrl": "https://github.com/chizy7/AlgoStream",
  "entries": {
    "Benchmark": [
      {
        "commit": {
          "author": {
            "email": "32227554+chizy7@users.noreply.github.com",
            "name": "Chizy",
            "username": "chizy7"
          },
          "committer": {
            "email": "noreply@github.com",
            "name": "GitHub",
            "username": "web-flow"
          },
          "distinct": true,
          "id": "26b6b07af68c3520cf22d7d7c12c790cf2779ff3",
          "message": "Merge pull request #5 from chizy7/pages\n\nci: create gh-pages if missing so the first Pages publish can land",
          "timestamp": "2026-08-15T17:45:07-04:00",
          "tree_id": "5286319787af1082f6a5bba54bc8ce94d049b956",
          "url": "https://github.com/chizy7/AlgoStream/commit/26b6b07af68c3520cf22d7d7c12c790cf2779ff3"
        },
        "date": 1786830881855,
        "tool": "customSmallerIsBetter",
        "benches": [
          {
            "name": "Monotonic Clock",
            "value": 189,
            "unit": "ns",
            "extra": "p95=100ns p99=100ns iter=10000"
          },
          {
            "name": "Realtime Clock",
            "value": 105,
            "unit": "ns",
            "extra": "p95=101ns p99=101ns iter=10000"
          },
          {
            "name": "Ring Buffer Push",
            "value": 70,
            "unit": "ns",
            "extra": "p95=71ns p99=71ns iter=10000"
          },
          {
            "name": "Ring Buffer Pop",
            "value": 69,
            "unit": "ns",
            "extra": "p95=71ns p99=71ns iter=10000"
          },
          {
            "name": "SPSC Queue Enqueue",
            "value": 35,
            "unit": "ns",
            "extra": "p95=41ns p99=41ns iter=10000"
          },
          {
            "name": "SPSC Queue Dequeue",
            "value": 65,
            "unit": "ns",
            "extra": "p95=40ns p99=40ns iter=10000"
          },
          {
            "name": "Fast Inverse Square Root",
            "value": 45,
            "unit": "ns",
            "extra": "p95=41ns p99=41ns iter=10000"
          },
          {
            "name": "Fast Logarithm",
            "value": 80,
            "unit": "ns",
            "extra": "p95=60ns p99=60ns iter=10000"
          },
          {
            "name": "Fast Exponential",
            "value": 63,
            "unit": "ns",
            "extra": "p95=80ns p99=80ns iter=10000"
          },
          {
            "name": "Critical Path: Timestamp Generation",
            "value": 80,
            "unit": "ns",
            "extra": "p95=71ns p99=71ns iter=100000"
          },
          {
            "name": "Critical Path: Ring Buffer Operations",
            "value": 2112,
            "unit": "ns",
            "extra": "p95=882ns p99=882ns iter=100000"
          },
          {
            "name": "Critical Path: Math Operations",
            "value": 50,
            "unit": "ns",
            "extra": "p95=41ns p99=41ns iter=100000"
          },
          {
            "name": "event_bus.saturated_queueing.avg",
            "value": 5943938,
            "unit": "ns",
            "extra": "n=50000"
          },
          {
            "name": "event_bus.saturated_queueing.p50",
            "value": 6271355,
            "unit": "ns",
            "extra": "n=50000"
          },
          {
            "name": "event_bus.saturated_queueing.p95",
            "value": 8815153,
            "unit": "ns",
            "extra": "n=50000"
          },
          {
            "name": "event_bus.saturated_queueing.p99",
            "value": 9264346,
            "unit": "ns",
            "extra": "n=50000"
          },
          {
            "name": "event_bus.throughput.ns_per_event",
            "value": 548,
            "unit": "ns",
            "extra": "n=200000 throughput=1822387 ev/s"
          },
          {
            "name": "ingestion.binance.ns_per_event",
            "value": 3550,
            "unit": "ns",
            "extra": "throughput=281663 ev/s"
          },
          {
            "name": "ingestion.coinbase.ns_per_event",
            "value": 3662,
            "unit": "ns",
            "extra": "throughput=273044 ev/s"
          },
          {
            "name": "ingestion.binance.alloc_bytes_per_event",
            "value": 1699.3,
            "unit": "B",
            "extra": "words=212.4"
          },
          {
            "name": "ingestion.coinbase.alloc_bytes_per_event",
            "value": 2307.3,
            "unit": "B",
            "extra": "words=288.4"
          },
          {
            "name": "analytics.direct.ns_per_event",
            "value": 39384,
            "unit": "ns",
            "extra": "throughput=25391 ev/s"
          },
          {
            "name": "analytics.bus.ns_per_event",
            "value": 23588,
            "unit": "ns",
            "extra": "published=50000 processed=47502"
          },
          {
            "name": "time_series.bar_builder.ns_per_tick",
            "value": 18,
            "unit": "ns",
            "extra": "throughput=53651572 tick/s bars=1000"
          },
          {
            "name": "time_series.compress.float_bytes_per_value",
            "value": 9,
            "unit": "B",
            "extra": "ratio=1.12"
          },
          {
            "name": "time_series.compress.int64_bytes_per_value",
            "value": 3.79,
            "unit": "B",
            "extra": "ratio=0.47"
          },
          {
            "name": "pairs.direct.ns_per_event",
            "value": 945,
            "unit": "ns",
            "extra": "throughput=1057149 ev/s"
          },
          {
            "name": "pairs.bus.ns_per_event",
            "value": 1820,
            "unit": "ns",
            "extra": "published=100000 processed=90087"
          },
          {
            "name": "adv.kalman_hedge.ns_per_event",
            "value": 71,
            "unit": "ns",
            "extra": "throughput=14065093 ev/s"
          },
          {
            "name": "adv.garch11.ns_per_event",
            "value": 27,
            "unit": "ns",
            "extra": "throughput=36781270 ev/s"
          },
          {
            "name": "adv.pca.fit_ms",
            "value": 1.39,
            "unit": "ms",
            "extra": "features=32 samples=500"
          },
          {
            "name": "oms.routing.ns_per_event",
            "value": 548,
            "unit": "ns",
            "extra": "throughput=1822705 ev/s"
          },
          {
            "name": "oms.book_impact.ns_per_event",
            "value": 24,
            "unit": "ns",
            "extra": "throughput=40664464 ev/s"
          },
          {
            "name": "oms.kelly.ns_per_event",
            "value": 24,
            "unit": "ns",
            "extra": "throughput=41122113 ev/s"
          },
          {
            "name": "risk.var_parametric.ns_per_event",
            "value": 7122,
            "unit": "ns",
            "extra": "throughput=140405 ev/s"
          },
          {
            "name": "risk.var_historical.ns_per_event",
            "value": 44709,
            "unit": "ns",
            "extra": "throughput=22367 ev/s"
          },
          {
            "name": "risk.drawdown.ns_per_event",
            "value": 15,
            "unit": "ns",
            "extra": "throughput=63601123 ev/s"
          },
          {
            "name": "risk.monitor.ns_per_event",
            "value": 15762,
            "unit": "ns",
            "extra": "throughput=63443 ev/s"
          },
          {
            "name": "sto.rng_uniform.ns_per_draw",
            "value": 21,
            "unit": "ns",
            "extra": "throughput=46322462 draws/s"
          },
          {
            "name": "sto.rng_int_below.ns_per_draw",
            "value": 24,
            "unit": "ns",
            "extra": "throughput=41067226 draws/s"
          },
          {
            "name": "sto.variate_normal.ns_per_draw",
            "value": 88,
            "unit": "ns",
            "extra": "throughput=11313602 draws/s"
          },
          {
            "name": "sto.rng_substream.ns_per_stream",
            "value": 38,
            "unit": "ns",
            "extra": "throughput=26223612 streams/s"
          },
          {
            "name": "bt.frictionless.ns_per_event",
            "value": 1427,
            "unit": "ns",
            "extra": "throughput=700380 ev/s"
          },
          {
            "name": "bt.spread_fees.ns_per_event",
            "value": 1394,
            "unit": "ns",
            "extra": "throughput=716928 ev/s"
          },
          {
            "name": "bt.book_walk.ns_per_event",
            "value": 1311,
            "unit": "ns",
            "extra": "throughput=762563 ev/s"
          },
          {
            "name": "metrics.of_nav.ns_per_call",
            "value": 5660336,
            "unit": "ns",
            "extra": "5000 points, 177 calls/s"
          },
          {
            "name": "metrics.drawdown_episodes.ns_per_call",
            "value": 19168,
            "unit": "ns",
            "extra": "5000 points"
          },
          {
            "name": "metrics.benchmark_compare.ns_per_call",
            "value": 167016,
            "unit": "ns",
            "extra": "5000 points"
          },
          {
            "name": "telemetry.histogram.record",
            "value": 22,
            "unit": "ns",
            "extra": "iter=2000000"
          },
          {
            "name": "telemetry.histogram.percentile",
            "value": 356,
            "unit": "ns",
            "extra": "iter=2000000"
          },
          {
            "name": "telemetry.bus.publish_with_collector",
            "value": 450,
            "unit": "ns",
            "extra": "iter=2000000"
          },
          {
            "name": "telemetry.collector.snapshot",
            "value": 3818,
            "unit": "ns",
            "extra": "iter=2000000"
          },
          {
            "name": "mc.path_level_1domain.ns_per_run",
            "value": 939408,
            "unit": "ns",
            "extra": "1064 runs/s"
          },
          {
            "name": "mc.path_level_8domain.ns_per_run",
            "value": 1807342,
            "unit": "ns",
            "extra": "speedup=2.58x"
          }
        ]
      }
    ]
  }
}