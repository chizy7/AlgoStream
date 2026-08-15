#!/usr/bin/env bash
# Heap-profile the event replay binary with valgrind --tool=massif.
# Use --pages-as-heap to capture mmap-backed allocations too.

set -euo pipefail

BIN="${BIN:-_build/default/bin/event_replay.exe}"
ARGS="${ARGS:-}"
OUT_PREFIX="${OUT_PREFIX:-massif.out}"

if ! command -v valgrind >/dev/null 2>&1; then
  echo "error: valgrind not found. Use 'make docker-shell' or install valgrind." >&2
  exit 1
fi

if [ ! -x "${BIN}" ]; then
  echo "error: ${BIN} not built. Run 'make build' first." >&2
  echo "       (benchmark.exe also works as a target.)" >&2
  exit 1
fi

echo "==> valgrind --tool=massif --pages-as-heap=yes --massif-out-file=${OUT_PREFIX}.%p ${BIN} ${ARGS}"
valgrind \
  --tool=massif \
  --pages-as-heap=yes \
  --massif-out-file="${OUT_PREFIX}.%p" \
  "${BIN}" ${ARGS}

LATEST="$(ls -t ${OUT_PREFIX}.* 2>/dev/null | head -n1 || true)"
if [ -n "${LATEST}" ]; then
  echo "==> Wrote ${LATEST}. Inspect with:"
  echo "    ms_print ${LATEST}"
  echo "    massif-visualizer ${LATEST}   (GUI, requires X11)"
fi
