#!/usr/bin/env bash
# Back up the audit log and keystore.
#
#   scripts/backup.sh --audit-dir DIR [--keys FILE] [--out DIR]
#
# Verifies the chain BEFORE archiving and refuses on a break. That ordering is the whole point: an
# archive of a already-broken chain preserves the tampering rather than the evidence of what the log
# said beforehand, and you find out months later. Pass --force to archive anyway, which is the right
# call when the break is what you are trying to preserve.
#
# The head hash is written next to the archive. That file is the out-of-band anchor the audit log's
# threat model depends on — the chain is unkeyed, so anyone who can write the log can recompute it,
# and the only thing that catches a wholesale rewrite is a hash recorded somewhere the daemon cannot
# reach. Copy it off this machine.

set -euo pipefail

AUDIT_DIR=""
KEYS_FILE=""
OUT_DIR="./backups"
FORCE=0

while [[ $# -gt 0 ]]; do
  case "$1" in
    --audit-dir) AUDIT_DIR="$2"; shift 2 ;;
    --keys)      KEYS_FILE="$2"; shift 2 ;;
    --out)       OUT_DIR="$2";   shift 2 ;;
    --force)     FORCE=1;        shift ;;
    -h|--help)   sed -n '2,16p' "$0"; exit 0 ;;
    *) echo "unknown argument: $1" >&2; exit 2 ;;
  esac
done

[[ -n "$AUDIT_DIR" ]] || { echo "--audit-dir is required" >&2; exit 2; }
[[ -d "$AUDIT_DIR" ]] || { echo "no such directory: $AUDIT_DIR" >&2; exit 2; }

AUDITCTL="${AUDITCTL:-algostream-auditctl}"
command -v "$AUDITCTL" >/dev/null || AUDITCTL="./_build/default/bin/auditctl.exe"
command -v "$AUDITCTL" >/dev/null || [[ -x "$AUDITCTL" ]] || {
  echo "algostream-auditctl not found; set AUDITCTL=/path/to/it" >&2; exit 2; }

echo "verifying the chain before archiving"
if ! "$AUDITCTL" verify "$AUDIT_DIR"; then
  if [[ "$FORCE" != "1" ]]; then
    echo "REFUSING to archive a broken chain. Investigate first; --force to archive anyway." >&2
    exit 1
  fi
  echo "chain is broken; archiving anyway because --force was given" >&2
fi

mkdir -p "$OUT_DIR"
STAMP=$(date -u +%Y%m%dT%H%M%SZ)
ARCHIVE="$OUT_DIR/algostream-$STAMP.tar.gz"

# The keystore holds only hashes, so this archive is not itself a credential — but it is still an
# inventory of who has access, so it inherits 0600 either way.
FILES=("$AUDIT_DIR")
[[ -n "$KEYS_FILE" && -f "$KEYS_FILE" ]] && FILES+=("$KEYS_FILE")

tar -czf "$ARCHIVE" "${FILES[@]}"
chmod 600 "$ARCHIVE"

"$AUDITCTL" head "$AUDIT_DIR" > "$ARCHIVE.anchor" 2>/dev/null || true
chmod 600 "$ARCHIVE.anchor"

# The archive's own digest, so a restore can prove the archive itself was not altered.
if command -v shasum >/dev/null; then shasum -a 256 "$ARCHIVE" > "$ARCHIVE.sha256"
elif command -v sha256sum >/dev/null; then sha256sum "$ARCHIVE" > "$ARCHIVE.sha256"; fi

echo
echo "archive : $ARCHIVE"
echo "anchor  : $ARCHIVE.anchor"
cat "$ARCHIVE.anchor" 2>/dev/null | sed 's/^/          /'
echo
echo "Copy the anchor somewhere this machine cannot write. Without it, a rewritten log verifies"
echo "perfectly and there is nothing to compare against."
