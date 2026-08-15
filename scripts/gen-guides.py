#!/usr/bin/env python3
"""
gen-guides.py — render docs/guides/*.md as AlgoStream documentation pages.

    docs/guides/*.md  ─┐
    site/guides.toml  ─┼─▶  gen-guides.py --out DIR  ─▶  DIR/guides/*.html
    site/diagrams/*   ─┘                                 DIR/guides/index.html

The markdown is the single source of truth; nothing this script writes is
committed. It emits exactly the markup site/assets/guide.css already
styles, so generated pages match the rest of the site.

This is not a general CommonMark implementation. It covers the subset
docs/guides/ actually uses, and is strict about the rest: unknown link
targets and guides missing from guides.toml are hard errors, so a rename
fails the build instead of silently producing a dead page.

Standard library only — no pip install. Requires Python 3.11+ (tomllib).
"""

import argparse
import html
import re
import shutil
import sys
import tomllib
from pathlib import Path

REPO = Path(__file__).resolve().parent.parent
GUIDES_MD = REPO / "docs" / "guides"
SITE = REPO / "site"
DIAGRAMS = SITE / "diagrams"
BLOB = "https://github.com/chizy7/AlgoStream/blob/main/"
TREE = "https://github.com/chizy7/AlgoStream"

# `sh` appears only in event_bus.md; every other guide says `bash`.
LANG_ALIAS = {"sh": "bash", "": "output", None: "output"}
# Only OCaml gets highlighted. Several `ocaml` blocks are actually dune
# s-expressions or contain `...` placeholders; highlight.js is regex-based
# and degrades to plain text, which is fine.
HIGHLIGHT = {"ocaml"}

NUL = "\x00"


def die(msg):
    print(f"gen-guides: error: {msg}", file=sys.stderr)
    sys.exit(1)


def slugify(stem):
    """docs/guides stem -> URL slug. data_ingestion -> data-ingestion."""
    return stem.replace("_", "-")


def anchor(text, taken):
    """Heading text -> stable anchor. Non-ASCII is dropped, so
    '## β estimator choices' becomes 'estimator-choices'."""
    s = re.sub(r"<[^>]+>", "", text).lower()
    s = re.sub(r"[^a-z0-9]+", "-", s).strip("-")
    if not s:
        s = "section"
    base, n = s, 2
    while s in taken:
        s = f"{base}-{n}"
        n += 1
    taken.add(s)
    return s


# ───────────────────────── inline rendering ─────────────────────────

CODE_RE = re.compile(r"(`+)(.+?)\1", re.S)
LINK_RE = re.compile(r"\[([^\]]*)\]\(([^)\s]+)\)")
STRONG_RE = re.compile(r"\*\*(.+?)\*\*", re.S)
EM_STAR_RE = re.compile(r"(?<![\w*])\*([^*\n]+)\*(?![\w*])")
EM_US_RE = re.compile(r"(?<![\w_])_([^_\n]+)_(?![\w_])")


class Ctx:
    """Everything the renderer needs that is not the text itself."""

    def __init__(self, known_slugs, source_rel):
        self.known = known_slugs      # md stem -> slug, for foo.md links
        self.source = source_rel      # for error messages


def rewrite_href(url, ctx):
    """Return (href, is_external). Hard-fails on an unresolvable .md."""
    if url.startswith(("http://", "https://", "mailto:", "#")):
        return url, url.startswith("http")
    if url.endswith(".md"):
        stem = Path(url).stem
        if stem not in ctx.known:
            die(f"{ctx.source}: link to '{url}' but there is no such guide")
        return ctx.known[stem] + ".html", False
    if url.startswith("../../"):
        # Points at source, not a page — send it to GitHub.
        return BLOB + url[len("../../"):], True
    if url.startswith("../"):
        return BLOB + url[len("../"):], True
    return url, False


def render_inline(text, ctx):
    """Markdown inline -> HTML.

    Order matters. Code spans are lifted out first so that neither the
    link scanner nor the emphasis scanner can see inside them — that is
    what protects '][' in `P⁻[0][0] + 2·x·P⁻[0][1]` and the escaped pipes
    that live inside code spans in table cells.
    """
    spans = []

    def take_code(m):
        body = m.group(2)
        # CommonMark: one leading+trailing space is stripped when both
        # are present. That is how ``  `Too_large n`  `` keeps its
        # backticks (OCaml polymorphic variant syntax).
        if len(body) > 1 and body[0] == " " and body[-1] == " " and body.strip():
            body = body[1:-1]
        spans.append(body)
        return f"{NUL}{len(spans) - 1}{NUL}"

    text = CODE_RE.sub(take_code, text)

    # Escape before inserting our own tags. Only & < > change, so the
    # markdown punctuation the later regexes match is untouched.
    text = html.escape(text, quote=False)

    def link(m):
        label, url = m.group(1), m.group(2)
        # html.escape turned &amp; back on us inside the URL; that is
        # correct for an href attribute, so leave it.
        href, external = rewrite_href(html.unescape(url), ctx)
        rel = ' rel="noopener"' if external else ""
        return f'<a href="{html.escape(href, quote=True)}"{rel}>{label}</a>'

    text = LINK_RE.sub(link, text)
    text = STRONG_RE.sub(r"<strong>\1</strong>", text)
    text = EM_STAR_RE.sub(r"<em>\1</em>", text)
    text = EM_US_RE.sub(r"<em>\1</em>", text)

    def restore(m):
        return "<code>" + html.escape(spans[int(m.group(1))], quote=False) + "</code>"

    return re.sub(rf"{NUL}(\d+){NUL}", restore, text)


# ───────────────────────── block parsing ─────────────────────────

FENCE_RE = re.compile(r"^(\s*)```(\S*)\s*$")
HEADING_RE = re.compile(r"^(#{1,6})\s+(.*?)\s*#*$")
HR_RE = re.compile(r"^\s{0,3}(-{3,}|\*{3,}|_{3,})\s*$")
ITEM_RE = re.compile(r"^(\s*)([-*+]|(\d+)\.)\s+(.*)$")
TASK_RE = re.compile(r"^\[([ xX])\]\s+(.*)$")
TABLE_DELIM_RE = re.compile(r"^\s*\|?\s*:?-{2,}:?\s*(\|\s*:?-{2,}:?\s*)*\|?\s*$")


def split_table_row(row):
    """Split on unescaped '|', unescaping '\\|' as we go.

    Doing it in one pass is the point: splitting first and unescaping
    after (or running the code-span scanner before the split) breaks the
    three rows in the corpus that carry escaped pipes, two of which sit
    inside inline code.
    """
    row = row.strip()
    if row.startswith("|"):
        row = row[1:]
    if row.endswith("|") and not row.endswith("\\|"):
        row = row[:-1]
    cells, buf, i = [], "", 0
    while i < len(row):
        c = row[i]
        if c == "\\" and i + 1 < len(row) and row[i + 1] == "|":
            buf += "|"
            i += 2
            continue
        if c == "|":
            cells.append(buf)
            buf = ""
            i += 1
            continue
        buf += c
        i += 1
    cells.append(buf)
    return [c.strip() for c in cells]


def read_fence(lines, i):
    """Consume a fenced block starting at i. Returns (lang, body, next_i)."""
    m = FENCE_RE.match(lines[i])
    indent, lang = len(m.group(1)), m.group(2).strip().lower()
    body, i = [], i + 1
    while i < len(lines):
        if FENCE_RE.match(lines[i]) and not FENCE_RE.match(lines[i]).group(2):
            i += 1
            break
        body.append(lines[i][indent:] if lines[i][:indent].strip() == "" else lines[i])
        i += 1
    return lang, body, i


class Renderer:
    def __init__(self, ctx, slug, diagram_dir):
        self.ctx = ctx
        self.slug = slug
        self.diagrams = diagram_dir
        self.mermaid_n = 0
        self.stats = {"tables": 0, "code": 0, "diagrams": 0, "fallback": []}

    # ── leaf renderers ────────────────────────────────────────────

    def code_block(self, lang, body):
        lang = LANG_ALIAS.get(lang, lang)
        self.stats["code"] += 1
        attr = f' data-lang="{html.escape(lang, quote=True)}"' if lang in HIGHLIGHT else ""
        text = html.escape("\n".join(body).rstrip("\n"), quote=False)
        return (
            f'<div class="code" data-label="{html.escape(lang, quote=True)}">'
            f"<pre><code{attr}>{text}</code></pre></div>"
        )

    def mermaid(self, body):
        self.mermaid_n += 1
        part = self.diagrams / f"{self.slug}-{self.mermaid_n}.html"
        if part.is_file():
            self.stats["diagrams"] += 1
            return part.read_text(encoding="utf-8").rstrip("\n")
        # No hand-drawn override — show the source rather than nothing.
        self.stats["fallback"].append(f"{self.slug}-{self.mermaid_n}")
        return self.code_block("mermaid", body)

    def table(self, header, rows):
        self.stats["tables"] += 1
        out = ['<div class="tbl"><div class="tbl-scroll"><table><thead><tr>']
        out += [f"<th>{render_inline(c, self.ctx)}</th>" for c in header]
        out.append("</tr></thead><tbody>")
        for r in rows:
            r = (r + [""] * len(header))[: len(header)]
            out.append("<tr>" + "".join(
                f"<td>{render_inline(c, self.ctx)}</td>" for c in r) + "</tr>")
        out.append("</tbody></table></div></div>")
        return "".join(out)

    def callout(self, lines):
        body = "\n".join(lines).strip()
        head = ""
        m = re.match(r"^\*\*(.+?)\*\*\s*(.*)$", body, re.S)
        if m:
            head = f'<span class="q">{render_inline(m.group(1), self.ctx)}</span>'
            body = m.group(2).strip()
        paras = [p.strip() for p in re.split(r"\n\s*\n", body) if p.strip()]
        inner = "".join(f"<p>{render_inline(p, self.ctx)}</p>" for p in paras)
        return f'<div class="callout">{head}{inner}</div>'

    # ── list ──────────────────────────────────────────────────────

    def render_list(self, lines, i):
        """Consume one list. Handles hanging-indent continuation (the most
        common non-baseline construct in the corpus) and a fenced block
        nested inside an item."""
        base = len(ITEM_RE.match(lines[i]).group(1))
        ordered = ITEM_RE.match(lines[i]).group(3) is not None
        items, cur = [], None

        while i < len(lines):
            line = lines[i]
            m = ITEM_RE.match(line)

            if m and len(m.group(1)) <= base:
                if (m.group(3) is not None) != ordered:
                    break
                cur = {"text": [m.group(4)], "blocks": []}
                items.append(cur)
                i += 1
                continue

            if cur is None:
                break

            if not line.strip():
                # A blank line continues the list only if more indented
                # content follows; otherwise the list ends.
                j = i + 1
                while j < len(lines) and not lines[j].strip():
                    j += 1
                if j < len(lines) and lines[j].startswith(" ") and \
                        not ITEM_RE.match(lines[j]):
                    i = j
                    continue
                if j < len(lines) and ITEM_RE.match(lines[j]) and \
                        len(ITEM_RE.match(lines[j]).group(1)) <= base:
                    i = j
                    continue
                break

            if line.startswith(" "):
                if FENCE_RE.match(line):
                    lang, body, i = read_fence(lines, i)
                    blk = self.mermaid(body) if lang == "mermaid" \
                        else self.code_block(lang, body)
                    cur["blocks"].append(blk)
                    continue
                cur["text"].append(line.strip())
                i += 1
                continue

            break

        tag = "ol" if ordered else "ul"
        out, is_task = [], False
        for it in items:
            text = " ".join(it["text"]).strip()
            tm = TASK_RE.match(text)
            if tm:
                is_task = True
                mark = "x" if tm.group(1).lower() == "x" else " "
                inner = (f'<span class="box" aria-hidden="true">'
                         f'{"&#10003;" if mark == "x" else "&#183;"}</span>'
                         f"{render_inline(tm.group(2), self.ctx)}")
            else:
                inner = render_inline(text, self.ctx)
            out.append(f"<li>{inner}{''.join(it['blocks'])}</li>")
        cls = ' class="task"' if is_task else ""
        return f"<{tag}{cls}>" + "".join(out) + f"</{tag}>", i

    # ── the main block loop ───────────────────────────────────────

    def render_blocks(self, lines):
        """Render a run of lines that contains no H1/H2 (those are handled
        by the section splitter)."""
        out, i, n = [], 0, len(lines)
        while i < n:
            line = lines[i]

            if not line.strip():
                i += 1
                continue

            if FENCE_RE.match(line):
                lang, body, i = read_fence(lines, i)
                out.append(self.mermaid(body) if lang == "mermaid"
                           else self.code_block(lang, body))
                continue

            hm = HEADING_RE.match(line)
            if hm:
                lvl = len(hm.group(1))
                text = re.sub(r"^\d+\.\s+", "", hm.group(2))
                out.append(f"<h{lvl}>{render_inline(text, self.ctx)}</h{lvl}>")
                i += 1
                continue

            if HR_RE.match(line):
                out.append("<hr>")
                i += 1
                continue

            if line.lstrip().startswith(">"):
                buf = []
                while i < n and lines[i].lstrip().startswith(">"):
                    buf.append(re.sub(r"^\s*>\s?", "", lines[i]))
                    i += 1
                out.append(self.callout(buf))
                continue

            if line.lstrip().startswith("|") and i + 1 < n and \
                    TABLE_DELIM_RE.match(lines[i + 1]):
                header = split_table_row(line)
                i += 2
                rows = []
                while i < n and lines[i].lstrip().startswith("|"):
                    rows.append(split_table_row(lines[i]))
                    i += 1
                out.append(self.table(header, rows))
                continue

            if ITEM_RE.match(line):
                blk, i = self.render_list(lines, i)
                out.append(blk)
                continue

            para = []
            while i < n and lines[i].strip() and not FENCE_RE.match(lines[i]) \
                    and not HEADING_RE.match(lines[i]) and not HR_RE.match(lines[i]) \
                    and not ITEM_RE.match(lines[i]) \
                    and not lines[i].lstrip().startswith(">") \
                    and not lines[i].lstrip().startswith("|"):
                para.append(lines[i].strip())
                i += 1
            if para:
                out.append(f"<p>{render_inline(' '.join(para), self.ctx)}</p>")
            elif i < n and lines[i].strip():
                i += 1  # nothing matched; do not spin
        return "".join(out)


# ───────────────────────── page assembly ─────────────────────────


def split_sections(lines):
    """-> (h1_text, lede_lines, [(h2_text, body_lines)])"""
    h1, lede, sections = None, [], []
    cur = None
    in_fence = False
    for line in lines:
        if FENCE_RE.match(line):
            in_fence = not in_fence
        if not in_fence:
            m = HEADING_RE.match(line)
            if m and len(m.group(1)) == 1 and h1 is None:
                h1 = m.group(2)
                continue
            if m and len(m.group(1)) == 2:
                cur = [re.sub(r"^\d+\.\s+", "", m.group(2)), []]
                sections.append(cur)
                continue
        (cur[1] if cur else lede).append(line)
    return h1, lede, sections


HEAD = """<!doctype html>
<html lang="en">
<head>
  <meta charset="utf-8">
  <meta name="viewport" content="width=device-width, initial-scale=1">
  <meta name="color-scheme" content="dark">
  <title>{title} — AlgoStream</title>
  <meta name="description" content="{desc}">
  <meta name="theme-color" content="#0A0A0B">
  <meta property="og:title" content="{title} — AlgoStream">
  <meta property="og:description" content="{desc}">
  <meta property="og:type" content="article">
  <link rel="icon" href="data:image/svg+xml,%3Csvg xmlns='http://www.w3.org/2000/svg' viewBox='0 0 32 32'%3E%3Crect width='32' height='32' fill='%230A0A0B'/%3E%3Cpath d='M6 22 L12 10 L18 18 L22 13 L26 22' stroke='%23FFA21A' stroke-width='2' fill='none' stroke-linecap='square'/%3E%3C/svg%3E">
  <link rel="stylesheet" href="../assets/algostream.css">
  <link rel="stylesheet" href="../assets/guide.css">
</head>
<body>
  <div class="canvas"   aria-hidden="true"></div>
  <div class="vignette" aria-hidden="true"></div>
  <div class="grain"    aria-hidden="true"></div>

  <main class="shell">
"""

FOOT = """  </main>
  <script src="../assets/highlight.js"></script>
  <script src="../assets/guide-nav.js"></script>
</body>
</html>
"""


def statusbar(crumb, right_a, right_b):
    return f"""    <header class="statusbar">
      <div class="group">
        <a class="backlink" href="../"><span class="glyph" aria-hidden="true">←</span><span class="mark">ALGOSTREAM</span></a>
        <span class="sep">/</span>
        <a class="backlink" href="./">guides</a>
        <span class="sep">/</span>
        <span style="color:var(--cream)">{crumb}</span>
      </div>
      <div class="group">
        <span>{right_a}</span>
        <span class="sep">/</span>
        <span class="live"><span class="live-dot" aria-hidden="true"></span>{right_b}</span>
      </div>
    </header>
"""


def accent_h1(h1, accent):
    e = html.escape(h1, quote=False)
    if accent and accent in h1:
        a = html.escape(accent, quote=False)
        return e.replace(a, f'<span class="accent">{a}</span>', 1)
    return e


def build_page(stem, meta, md_lines, known, prev_nav, next_nav):
    slug = slugify(stem)
    ctx = Ctx(known, f"docs/guides/{stem}.md")
    r = Renderer(ctx, slug, DIAGRAMS)

    h1_md, lede_lines, sections = split_sections(md_lines)
    h1 = meta.get("h1") or re.sub(r"\s+Guide$", "", h1_md or stem).lower()
    accent = meta.get("accent") or h1.split()[-1]

    # Everything between the H1 and the first H2. The opening prose
    # paragraph becomes the page lede; anything after it is real content
    # — seven guides put a "what's in the box" table up here — so it is
    # rendered as blocks and placed above the first numbered section.
    lede_para, intro_rest = [], []
    k = 0
    while k < len(lede_lines) and not lede_lines[k].strip():
        k += 1
    start = k
    first = lede_lines[k] if k < len(lede_lines) else ""
    if first.lstrip()[:1] in ("|", "-", "*", ">", "") or FENCE_RE.match(first) \
            or ITEM_RE.match(first):
        intro_rest = lede_lines[k:]          # opens with a block, not prose
    else:
        while k < len(lede_lines) and lede_lines[k].strip():
            k += 1
        lede_para = lede_lines[start:k]
        intro_rest = lede_lines[k:]

    lede_text = " ".join(l.strip() for l in lede_para if l.strip())
    lede_html = render_inline(lede_text, ctx) if lede_text else ""
    intro_html = r.render_blocks(intro_rest) if any(l.strip() for l in intro_rest) else ""
    desc = html.escape(re.sub(r"<[^>]+>", "", lede_html)[:180], quote=True)

    # meta chips
    chips = list(meta.get("meta", []))
    chip_html = "".join(
        f'<span><span class="k">{html.escape(c["k"])}</span>{render_inline(c["v"], ctx)}</span>'
        for c in chips)
    chip_html += (f'<span><span class="k">source</span>'
                  f'<a href="{BLOB}docs/guides/{stem}.md" rel="noopener">{stem}.md ↗</a></span>')

    # sections
    taken, toc, body = set(), [], []
    for idx, (title, blines) in enumerate(sections, 1):
        title_html = render_inline(title, ctx)
        aid = anchor(title_html, taken)
        toc.append(f'<li><a href="#{aid}">{title_html}</a></li>')
        inner = r.render_blocks(blines)
        body.append(
            f'<section id="{aid}"><h2><span class="num">{idx:02d}</span>{title_html}</h2>'
            f"{inner}</section>")

    nav = []
    if prev_nav:
        nav.append(f'<a class="btn btn-ghost pn" href="{prev_nav[0]}.html">'
                   f'<span class="dir">← previous</span><span>{html.escape(prev_nav[1])}</span></a>')
    nav.append('<a class="btn btn-ghost pn" href="./"><span class="dir">index</span>'
               '<span>All guides</span></a>')
    if next_nav:
        nav.append(f'<a class="btn btn-ghost pn" href="{next_nav[0]}.html">'
                   f'<span class="dir">next →</span><span>{html.escape(next_nav[1])}</span></a>')

    foot_lines = meta.get("footer")
    if foot_lines:
        rows = "\n".join(
            f"│ {html.escape(l, quote=False)}" for l in foot_lines)
        ascii_block = (f'<pre class="ascii-mark">┌─ <span class="dim">'
                       f'{html.escape(stem)}</span>\n{rows}\n└─</pre>')
    else:
        ascii_block = (f'<pre class="ascii-mark">┌─ <span class="dim">docs/guides</span>\n'
                       f"│ {html.escape(stem)}.md\n"
                       f"│ {len(sections)} sections · {r.stats['tables']} tables · "
                       f"{r.stats['code']} code blocks\n└─</pre>")

    out = [HEAD.format(title=html.escape(meta["nav_label"], quote=True), desc=desc)]
    # The nav group orients a reader ("Operations", "Market Data"); a development-phase number
    # does not. `status` is optional and appears only where it carries a real caveat.
    out.append(statusbar(html.escape(h1), html.escape(meta["group"]).lower(),
                         html.escape(meta.get("status", ""))))
    out.append(f"""    <div>
      <div class="guide-head">
        <p class="eyebrow">{html.escape(meta.get("group", "Guide"))}</p>
        <h1>{accent_h1(h1, accent)}</h1>
        <p class="lede">{lede_html}</p>
        <div class="guide-meta">{chip_html}</div>
      </div>

      <div class="doc">
        <nav class="toc" aria-label="On this page">
          <p class="toc-label">On this page</p>
          <ol>{''.join(toc)}</ol>
        </nav>
        <article class="prose">
          {f'<section class="intro">{intro_html}</section>' if intro_html else ''}
          {''.join(body)}
          <nav class="doc-nav">{''.join(nav)}</nav>
        </article>
      </div>
    </div>

    <footer class="footer">
      {ascii_block}
      <div></div>
      <div class="meta-right">
        <a href="../"><strong>github.io</strong> / algostream</a><br>
        {html.escape(meta["group"]).lower()} · {len(sections)} sections
      </div>
    </footer>
""")
    out.append(FOOT)
    return "".join(out), r.stats, len(sections)


INDEX_HEAD = HEAD.replace("../assets/", "../assets/")


def build_index(entries, groups, blurbs):
    total = len(entries)
    panels = []
    for g in groups:
        rows = [e for e in entries if e["meta"]["group"] == g]
        if not rows:
            continue
        cards = []
        for e in rows:
            m, s = e["meta"], e["stats"]
            def plural(n, word):
                return f"{n} {word}" + ("" if n == 1 else "s")

            bits = [plural(e["sections"], "section")]
            if s["tables"]:
                bits.append(plural(s["tables"], "table"))
            if s["diagrams"]:
                bits.append(plural(s["diagrams"], "diagram"))
            if s["code"]:
                bits.append(plural(s["code"], "code block"))
            cards.append(f"""<a class="gcard" href="./{e['slug']}.html">
              <span class="gname">{html.escape(m['nav_label'])}</span>
              <span class="gphase">{html.escape(m.get('status', ''))}</span>
              <span class="gbits">{' · '.join(bits)}</span>
            </a>""")
        panels.append(f"""      <div class="panel gsec">
        <span class="br-tr" aria-hidden="true"></span><span class="br-bl" aria-hidden="true"></span>
        <div class="panel-head"><span>{html.escape(g)}</span><span class="seq">{len(rows)} guides</span></div>
        <p class="gblurb">{html.escape(blurbs.get(g, ''))}</p>
        <div class="gcards">{''.join(cards)}</div>
      </div>""")

    head = HEAD.format(title="Documentation", desc=(
        "Every AlgoStream guide: event bus, ingestion, time series, pairs trading, "
        "risk, backtesting, Monte Carlo and performance tuning."))
    head = head.replace('href="../assets/', 'href="../assets/')
    return head + f"""    <header class="statusbar">
      <div class="group">
        <a class="backlink" href="../"><span class="glyph" aria-hidden="true">←</span><span class="mark">ALGOSTREAM</span></a>
        <span class="sep">/</span>
        <span style="color:var(--cream)">guides</span>
      </div>
      <div class="group">
        <span>{total} guides</span>
        <span class="sep">/</span>
        <span class="live"><span class="live-dot" aria-hidden="true"></span>generated from markdown</span>
      </div>
    </header>

    <div>
      <div class="guide-head">
        <p class="eyebrow">Documentation</p>
        <h1>the <span class="accent">guides</span></h1>
        <p class="lede">
          Every layer of AlgoStream, documented where it is built. These pages are generated from
          <code>docs/guides/*.md</code> — the markdown in the repository is the source of truth, so
          what you read here and what you read on GitHub cannot drift apart.
        </p>
      </div>

      <div class="gindex">
{''.join(panels)}
      </div>
    </div>

    <footer class="footer">
      <pre class="ascii-mark">┌─ <span class="dim">docs/guides</span>
│ {total} guides <span class="check">✓</span>  generated · no external requests
└─ source     <span class="check">✓</span>  markdown in-repo</pre>
      <div></div>
      <div class="meta-right">
        <a href="../"><strong>github.io</strong> / algostream</a><br>
        <a href="{TREE}/tree/main/docs/guides" rel="noopener">view markdown ↗</a>
      </div>
    </footer>
""" + FOOT


# ───────────────────────── main ─────────────────────────


def main():
    ap = argparse.ArgumentParser(description=__doc__.split("\n")[1])
    ap.add_argument("--out", required=True, help="output directory (guides/ is created inside)")
    ap.add_argument("--quiet", action="store_true")
    args = ap.parse_args()

    conf = tomllib.loads((SITE / "guides.toml").read_text(encoding="utf-8"))
    groups = conf.pop("_groups")
    blurbs = groups.get("blurb", {})
    group_order = groups["order"]

    on_disk = sorted(p.stem for p in GUIDES_MD.glob("*.md"))
    configured = sorted(conf)
    if on_disk != configured:
        missing = set(on_disk) - set(configured)
        extra = set(configured) - set(on_disk)
        msg = []
        if missing:
            msg.append(f"guides with no entry in site/guides.toml: {sorted(missing)}")
        if extra:
            msg.append(f"guides.toml entries with no markdown file: {sorted(extra)}")
        die("; ".join(msg))

    known = {stem: slugify(stem) for stem in on_disk}

    # Reading order: group order, then the `order` key within a group.
    ordered = sorted(on_disk, key=lambda s: (group_order.index(conf[s]["group"]),
                                             conf[s]["order"], s))

    out_dir = Path(args.out) / "guides"
    out_dir.mkdir(parents=True, exist_ok=True)

    entries, fallbacks = [], []
    for pos, stem in enumerate(ordered):
        meta = conf[stem]
        prev_nav = next_nav = None
        if pos > 0:
            p = ordered[pos - 1]
            prev_nav = (slugify(p), conf[p]["nav_label"])
        if pos < len(ordered) - 1:
            n = ordered[pos + 1]
            next_nav = (slugify(n), conf[n]["nav_label"])

        md = (GUIDES_MD / f"{stem}.md").read_text(encoding="utf-8").split("\n")
        page, stats, nsec = build_page(stem, meta, md, known, prev_nav, next_nav)
        (out_dir / f"{slugify(stem)}.html").write_text(page, encoding="utf-8")
        fallbacks += stats["fallback"]
        entries.append({"slug": slugify(stem), "meta": meta,
                        "stats": stats, "sections": nsec})

    (out_dir / "index.html").write_text(
        build_index(entries, group_order, blurbs), encoding="utf-8")

    if not args.quiet:
        for e in entries:
            s = e["stats"]
            print(f"  {e['slug']:24} {e['sections']:2} sections  "
                  f"{s['tables']:2} tables  {s['code']:2} code  {s['diagrams']} diagrams")
        print(f"gen-guides: wrote {len(entries)} guides + index to {out_dir}")
    if fallbacks:
        print(f"gen-guides: warning: no hand-drawn diagram for {fallbacks} "
              f"(rendered as code blocks)", file=sys.stderr)


if __name__ == "__main__":
    main()
