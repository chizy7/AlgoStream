#!/usr/bin/env bash
# AlgoStream developer setup. Creates an OCaml 5.1 switch in the project
# directory and installs all dependencies including dev tools.

set -euo pipefail

OCAML_VERSION="${OCAML_VERSION:-5.1.1}"
SWITCH_PATH="$(pwd)"

if ! command -v opam >/dev/null 2>&1; then
  echo "error: opam not found in PATH. Install opam first: https://opam.ocaml.org/doc/Install.html" >&2
  exit 1
fi

echo "==> Initializing opam (idempotent)"
opam init --bare --disable-sandbox --no-setup --yes >/dev/null

if [ ! -d "${SWITCH_PATH}/_opam" ]; then
  echo "==> Creating local switch at ${SWITCH_PATH} (OCaml ${OCAML_VERSION})"
  opam switch create . "ocaml-base-compiler.${OCAML_VERSION}" --no-install --yes
else
  echo "==> Reusing existing local switch at ${SWITCH_PATH}/_opam"
fi

eval "$(opam env --switch="${SWITCH_PATH}" --set-switch)"

echo "==> Installing project dependencies (--with-test)"
opam install . --deps-only --with-test --yes

# --with-dev-setup is opam 2.2+ only; install dev tools manually for 2.1 compat.
echo "==> Installing dev tools (ocaml-lsp-server / ocamlformat / utop)"
opam install ocaml-lsp-server ocamlformat utop --yes

echo "==> Installing memtrace-viewer (optional, for heap analysis)"
opam install memtrace_viewer --yes || echo "  (skipped — memtrace_viewer is optional)"

echo "==> Done."
echo "    Run 'eval \$(opam env)' to activate the switch in this shell."
echo "    Then: 'make build && make test'."
