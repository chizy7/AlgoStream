#!/usr/bin/env bash
# Run the benchmark suite and emit a JSON file in the
# customSmallerIsBetter schema consumed by github-action-benchmark.

set -euo pipefail

OUT="${OUT:-bench_results.json}"

opam exec -- dune build --profile release bin/benchmark.exe
opam exec -- dune exec --profile release bin/benchmark.exe -- --json "${OUT}"

echo "==> Wrote ${OUT}"
echo "    Schema: customSmallerIsBetter"
echo "    Each entry: { name, unit: \"ns\", value, extra }"
