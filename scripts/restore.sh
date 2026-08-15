#!/usr/bin/env bash
# Restore an audit-log archive and verify it against its anchor.
#
#   scripts/restore.sh --archive FILE --into DIR [--anchor FILE]
#
# Restoring is the easy half. The half that matters is the check afterwards: verify the chain, then
# compare the head hash against the anchor recorded when the backup was taken. The chain alone only
# proves internal consistency, which a wholesale rewrite also has. Only the anchor distinguishes
# "this is the log we backed up" from "this is a log".
#
# Refuses to overwrite a non-empty target, because the common way to destroy an audit trail during
# an incident is to restore over the live one.

set -euo pipefail

ARCHIVE=""
INTO=""
ANCHOR=""

while [[ $# -gt 0 ]]; do
  case "$1" in
    --archive) ARCHIVE="$2"; shift 2 ;;
    --into)    INTO="$2";    shift 2 ;;
    --anchor)  ANCHOR="$2";  shift 2 ;;
    -h|--help) sed -n '2,14p' "$0"; exit 0 ;;
    *) echo "unknown argument: $1" >&2; exit 2 ;;
  esac
done

[[ -n "$ARCHIVE" && -n "$INTO" ]] || { echo "--archive and --into are required" >&2; exit 2; }
[[ -f "$ARCHIVE" ]] || { echo "no such archive: $ARCHIVE" >&2; exit 2; }

if [[ -d "$INTO" ]] && [[ -n "$(ls -A "$INTO" 2>/dev/null)" ]]; then
  echo "REFUSING: $INTO is not empty. Restore into a fresh directory and move it into place" >&2
  echo "once verified — restoring over a live audit log is how one gets destroyed." >&2
  exit 1
fi

if [[ -f "$ARCHIVE.sha256" ]]; then
  echo "checking the archive digest"
  if command -v shasum >/dev/null; then (cd "$(dirname "$ARCHIVE")" && shasum -a 256 -c "$(basename "$ARCHIVE").sha256")
  elif command -v sha256sum >/dev/null; then (cd "$(dirname "$ARCHIVE")" && sha256sum -c "$(basename "$ARCHIVE").sha256"); fi
fi

mkdir -p "$INTO"
tar -xzf "$ARCHIVE" -C "$INTO"
echo "extracted into $INTO"

AUDITCTL="${AUDITCTL:-algostream-auditctl}"
command -v "$AUDITCTL" >/dev/null || AUDITCTL="./_build/default/bin/auditctl.exe"

RESTORED=$(find "$INTO" -type d -name 'audit*' -print -quit 2>/dev/null || true)
[[ -n "$RESTORED" ]] || RESTORED="$INTO"

echo
echo "verifying the restored chain"
"$AUDITCTL" verify "$RESTORED" || { echo "the restored log does not verify" >&2; exit 1; }

[[ -z "$ANCHOR" && -f "$ARCHIVE.anchor" ]] && ANCHOR="$ARCHIVE.anchor"

if [[ -n "$ANCHOR" && -f "$ANCHOR" ]]; then
  echo
  echo "comparing against the anchor"
  EXPECTED=$(awk '/^head/{print $2}' "$ANCHOR")
  ACTUAL=$("$AUDITCTL" head "$RESTORED" | awk '/^head/{print $2}')
  if [[ "$EXPECTED" == "$ACTUAL" ]]; then
    echo "  head matches the anchor: $ACTUAL"
  else
    echo "  MISMATCH" >&2
    echo "    anchor:   $EXPECTED" >&2
    echo "    restored: $ACTUAL" >&2
    echo "  The chain is internally consistent but is NOT the log that was backed up." >&2
    exit 1
  fi
else
  echo
  echo "WARNING: no anchor given, so this only proves internal consistency — which a rewritten"
  echo "log also has. Pass --anchor to make this check mean something."
fi
