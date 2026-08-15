#!/usr/bin/env bash
# Run the benchmark binary under `perf record` and emit a flame-graph-friendly
# perf.data. Linux only (perf is not available on macOS); intended to be run
# inside the Docker dev container on macOS hosts.

set -euo pipefail

BIN="${BIN:-_build/default/bin/benchmark.exe}"
FREQ="${FREQ:-999}"
OUT="${OUT:-perf.data}"

if [ "$(uname -s)" != "Linux" ]; then
  echo "error: perf is Linux-only. Use 'make docker-shell' first." >&2
  exit 1
fi

if ! command -v perf >/dev/null 2>&1; then
  echo "error: perf not found. Install linux-tools-generic." >&2
  exit 1
fi

if [ ! -x "${BIN}" ]; then
  echo "error: ${BIN} not built. Run 'make build' first." >&2
  exit 1
fi

echo "==> perf record -F ${FREQ} -g -o ${OUT} -- ${BIN}"
perf record -F "${FREQ}" -g -o "${OUT}" -- "${BIN}"

echo "==> Wrote ${OUT}. Inspect with:"
echo "    perf report -i ${OUT}"
echo "    perf script -i ${OUT} | stackcollapse-perf.pl | flamegraph.pl > flame.svg"
