#!/usr/bin/env python3
"""
check-guides.py — assert the generated documentation pages are correct.

Run after scripts/gen-guides.py. Compares each page against the markdown
it came from and fails on any discrepancy, so a parser regression shows
up in CI rather than on the published site.

    python3 scripts/gen-guides.py --out DIR --quiet
    python3 scripts/check-guides.py DIR

Standard library only.
"""

import html
import re
import sys
from html.parser import HTMLParser
from pathlib import Path

REPO = Path(__file__).resolve().parent.parent
GUIDES_MD = REPO / "docs" / "guides"

VOID = {"area", "base", "br", "col", "embed", "hr", "img", "input",
        "link", "meta", "param", "source", "track", "wbr"}

failures = []


def fail(msg):
    failures.append(msg)


# ───────────────────────── markdown facts ─────────────────────────

DELIM = re.compile(r"^\s*\|?\s*:?-{2,}:?\s*(\|\s*:?-{2,}:?\s*)*\|?\s*$")


def md_facts(path):
    """Ground truth from the markdown, ignoring anything inside fences."""
    lines = path.read_text(encoding="utf-8").split("\n")
    infence = False
    h2 = tables = fences = mermaid = 0
    for i, l in enumerate(lines):
        if l.lstrip().startswith("```"):
            if not infence:
                fences += 1
                if l.strip().lower() == "```mermaid":
                    mermaid += 1
            infence = not infence
            continue
        if infence:
            continue
        if l.startswith("## "):
            h2 += 1
        # A real table delimiter must follow a header row.
        if DELIM.match(l) and i > 0 and lines[i - 1].lstrip().startswith("|"):
            tables += 1
    return {"h2": h2, "tables": tables, "fences": fences, "mermaid": mermaid}


# ───────────────────────── HTML inspection ─────────────────────────


class Inspect(HTMLParser):
    """Well-formedness check + collect hrefs and prose text."""

    def __init__(self):
        super().__init__(convert_charrefs=True)
        self.stack = []
        self.hrefs = []
        self.prose = []
        self.errors = []
        self._skip = 0

    def handle_starttag(self, tag, attrs):
        d = dict(attrs)
        if tag == "a" and "href" in d:
            self.hrefs.append(d["href"])
        if tag in ("code", "pre"):
            self._skip += 1
        if tag not in VOID:
            self.stack.append(tag)

    def handle_endtag(self, tag):
        if tag in ("code", "pre"):
            self._skip = max(0, self._skip - 1)
        if tag in VOID:
            return
        if not self.stack:
            self.errors.append(f"stray </{tag}>")
            return
        if self.stack[-1] != tag:
            self.errors.append(f"</{tag}> closes <{self.stack[-1]}>")
            # resync
            if tag in self.stack:
                while self.stack and self.stack.pop() != tag:
                    pass
            return
        self.stack.pop()

    def handle_data(self, data):
        if not self._skip:
            self.prose.append(data)


def check_page(html_path, facts, is_index=False):
    name = html_path.name
    src = html_path.read_text(encoding="utf-8")

    p = Inspect()
    p.feed(src)
    for e in p.errors:
        fail(f"{name}: malformed HTML — {e}")
    if p.stack:
        fail(f"{name}: unclosed tags {p.stack}")

    if is_index:
        return p

    # counts
    n_sections = len(re.findall(r'<section id="', src))
    if n_sections != facts["h2"]:
        fail(f"{name}: {n_sections} sections but markdown has {facts['h2']} '## ' headings")

    n_tables = src.count('<div class="tbl">')
    if n_tables != facts["tables"]:
        fail(f"{name}: {n_tables} tables but markdown has {facts['tables']}")

    n_code = src.count('<div class="code"')
    n_diag = src.count('<div class="diagram">') + src.count('<div class="states">')
    expected_code = facts["fences"] - facts["mermaid"]
    if n_code != expected_code:
        fail(f"{name}: {n_code} code blocks but markdown has {expected_code} "
             f"non-mermaid fences")
    if n_diag != facts["mermaid"]:
        fail(f"{name}: {n_diag} diagrams but markdown has {facts['mermaid']} "
             f"mermaid blocks (a fallback code block means a missing partial)")

    # leaked markdown in prose (text outside <code>/<pre>)
    prose = "".join(p.prose)
    for pat, what in ((r"\]\(", "unrendered link"),
                      (r"```", "unrendered fence"),
                      (r"\*\*", "unrendered bold"),
                      (r"^\s*\|.*\|\s*$", "unrendered table row")):
        m = re.search(pat, prose, re.M)
        if m:
            ctx = prose[max(0, m.start() - 50):m.start() + 60].replace("\n", " ")
            fail(f"{name}: {what} leaked into prose: …{ctx.strip()}…")

    return p


def main():
    if len(sys.argv) != 2:
        print("usage: check-guides.py OUTDIR", file=sys.stderr)
        return 2
    out = Path(sys.argv[1]) / "guides"
    if not out.is_dir():
        print(f"check-guides: {out} does not exist", file=sys.stderr)
        return 2

    stems = sorted(p.stem for p in GUIDES_MD.glob("*.md"))
    pages = {}

    for stem in stems:
        slug = stem.replace("_", "-")
        page = out / f"{slug}.html"
        if not page.is_file():
            fail(f"{slug}.html: missing — no page generated for {stem}.md")
            continue
        pages[slug] = check_page(page, md_facts(GUIDES_MD / f"{stem}.md"))

    index = out / "index.html"
    if not index.is_file():
        fail("index.html: missing")
    else:
        pages["index"] = check_page(index, None, is_index=True)

    # every internal href must resolve
    existing = {p.name for p in out.glob("*.html")}
    for slug, p in pages.items():
        for href in p.hrefs:
            if href.startswith(("http://", "https://", "mailto:", "#", "data:")):
                continue
            target = href.split("#")[0]
            if target in ("", "./", "../"):
                continue
            if target.startswith("../"):
                continue          # site root, checked by the site build
            if target.startswith("./"):
                target = target[2:]
            if target not in existing:
                fail(f"{slug}.html: dead link -> {href}")

    extra = existing - {f"{s.replace('_', '-')}.html" for s in stems} - {"index.html"}
    if extra:
        fail(f"orphan pages with no markdown source: {sorted(extra)}")

    if failures:
        print(f"check-guides: {len(failures)} problem(s)\n", file=sys.stderr)
        for f in failures:
            print(f"  ✗ {f}", file=sys.stderr)
        return 1

    print(f"check-guides: ok — {len(stems)} guides + index, "
          f"structure and links verified")
    return 0


if __name__ == "__main__":
    sys.exit(main())
