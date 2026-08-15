#!/usr/bin/env python3
"""Security lints for AlgoStream.

Each check asserts a property the security design depends on, and each corresponds to a mistake
that is easy to make and hard to see in review.

The reason this is a script rather than a few `grep`s in the workflow: every one of these
constructs is *named in the documentation that explains why it is banned*. A plain grep flags
`api_key.mli`'s paragraph on why `unsafe_compare` must not be used, which is precisely backwards —
the lint would fire on the comment warning you not to do the thing. So OCaml comments and string
literals are stripped before matching, and only code is searched.
"""

from __future__ import annotations

import re
import sys
from pathlib import Path

ROOT = Path(__file__).resolve().parent.parent


def strip_ocaml(src: str) -> str:
    """Blank out (* comments *) and "string literals", preserving line structure.

    Comments nest in OCaml, so this tracks depth rather than matching the first `*)`. Newlines are
    kept so reported line numbers still mean something.
    """
    out = []
    i, n, depth = 0, len(src), 0
    in_string = False
    while i < n:
        ch = src[i]
        nxt = src[i + 1] if i + 1 < n else ""
        if not in_string and ch == "(" and nxt == "*":
            depth += 1
            out.append("  ")
            i += 2
            continue
        if depth > 0:
            if ch == "*" and nxt == ")":
                depth -= 1
                out.append("  ")
                i += 2
                continue
            out.append("\n" if ch == "\n" else " ")
            i += 1
            continue
        if ch == '"':
            in_string = not in_string
            out.append(" ")
            i += 1
            continue
        if in_string:
            # Skip an escaped character so \" does not end the literal early.
            if ch == "\\" and nxt:
                out.append("  ")
                i += 2
                continue
            out.append("\n" if ch == "\n" else " ")
            i += 1
            continue
        out.append(ch)
        i += 1
    return "".join(out)


def sources(rel: str):
    base = ROOT / rel
    if not base.exists():
        return
    for p in sorted(base.rglob("*")):
        # Skip macOS sync-conflict copies ("foo 2.ml"), which are not part of the build.
        if p.suffix in {".ml", ".mli"} and not re.search(r" \d+\.mli?$", p.name):
            yield p


def check_code(name: str, rel: str, pattern: str, message: str) -> bool:
    rx = re.compile(pattern)
    hits = []
    for p in sources(rel):
        for lineno, line in enumerate(strip_ocaml(p.read_text()).splitlines(), 1):
            if rx.search(line):
                hits.append(f"{p.relative_to(ROOT)}:{lineno}: {line.strip()}")
    if hits:
        print(f"FAIL  {name}")
        for h in hits:
            print(f"      {h}")
        print(f"      {message}")
        return False
    print(f"ok    {name}")
    return True


def check_committed_keys() -> bool:
    """A committed API key. The wire format is greppable on purpose."""
    rx = re.compile(r"ask_[0-9a-f]{8}_[a-z2-7]{52}")
    exts = {".ml", ".mli", ".md", ".yml", ".yaml", ".json", ".sh", ".c"}
    hits = []
    for p in sorted(ROOT.rglob("*")):
        if p.suffix not in exts or "_build" in p.parts or ".git" in p.parts:
            continue
        try:
            text = p.read_text()
        except (UnicodeDecodeError, OSError):
            continue
        for lineno, line in enumerate(text.splitlines(), 1):
            if rx.search(line):
                hits.append(f"{p.relative_to(ROOT)}:{lineno}")
    if hits:
        print("FAIL  no committed credentials")
        for h in hits:
            print(f"      {h}")
        print("      revoke it — it is in git history now, and deleting the line does not remove it")
        return False
    print("ok    no committed credentials")
    return True


def main() -> int:
    ok = True

    ok &= check_code(
        "constant-time digest comparison",
        "lib/infrastructure/auth",
        r"\bunsafe_compare\b",
        "Digestif.SHA256.equal is constant-time; unsafe_compare is documented as leaking.",
    )

    ok &= check_code(
        "auth does not use the reproducible PRNG",
        "lib/infrastructure/auth",
        r"\bAlgostream_rng\b|\bFastRandom\b|Random\.self_init",
        "Use Mirage_crypto_rng_unix.getrandom. lib/rng is deterministic by design.",
    )

    ok &= check_code(
        "audit log is append-only",
        "lib/infrastructure/persistence",
        r"\bO_TRUNC\b",
        "O_TRUNC would empty the audit trail on restart — that is why this module is not Event_log.",
    )

    ok &= check_code(
        "no query strings in network log calls",
        "lib/infrastructure/network",
        r"Log\.(debug|info|warn|err).*\bquery\b",
        "A query string may carry a single-use stream ticket; logging it writes a live credential.",
    )

    ok &= check_committed_keys()

    print()
    print("security-lint: " + ("all checks passed" if ok else "FAILURES ABOVE"))
    return 0 if ok else 1


if __name__ == "__main__":
    sys.exit(main())
