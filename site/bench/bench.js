/* ═══════════════════════════════════════════════════════════════════
   AlgoStream — benchmark dashboard
   Reads window.BENCHMARK_DATA from ./data.js, which
   benchmark-action/github-action-benchmark rewrites on every push to
   main. This file renders it; it never fetches anything.
   ═══════════════════════════════════════════════════════════════════ */
(function () {
  'use strict';

  /* Metric names carry a grouping prefix. Adding a new bench family is
     one line here — anything unmatched lands in FALLBACK. Order is
     roughly the order the subsystems were built. */
  var SECTIONS = [
    ['event_bus.',   'Event Bus'],
    ['ingestion.',   'Data Ingestion'],
    ['time_series.', 'Time Series'],
    ['analytics.',   'Analytics'],
    ['pairs.',       'Pairs Trading'],
    ['risk.',        'Risk Management'],
    ['oms.',         'Order Management'],
    ['adv.',         'Advanced Models'],
    ['sto.',         'Stochastic'],
    ['bt.',          'Backtesting'],
    ['metrics.',     'Performance Analytics'],
    ['mc.',          'Monte Carlo']
  ];
  var FALLBACK = 'Core Microbenchmarks';

  var W = 240, H = 42, PAD = 5;

  /* ───── tiny DOM helpers ───────────────────────────────────────── */

  function el(tag, cls, text) {
    var n = document.createElement(tag);
    if (cls) n.className = cls;
    if (text != null) n.textContent = text;
    return n;
  }

  function svg(tag, attrs) {
    var n = document.createElementNS('http://www.w3.org/2000/svg', tag);
    for (var k in attrs) if (Object.prototype.hasOwnProperty.call(attrs, k)) {
      n.setAttribute(k, attrs[k]);
    }
    return n;
  }

  function slug(s) {
    return s.toLowerCase().replace(/[^a-z0-9]+/g, '-').replace(/^-|-$/g, '');
  }

  /* ───── formatting ─────────────────────────────────────────────── */

  function fmtValue(v) {
    var a = Math.abs(v);
    if (Number.isInteger(v) && a < 1e9) return v.toLocaleString('en-US');
    if (a >= 1000) return v.toLocaleString('en-US', { maximumFractionDigits: 0 });
    if (a >= 100)  return v.toFixed(1);
    if (a >= 1)    return v.toFixed(2);
    return v.toPrecision(3);
  }

  /* Raw values span nine orders of magnitude — 42 ns next to 9,681,165 ns.
     Scale for the card so it stays glanceable; the tooltip keeps the exact
     measurement. The divisor is picked from the latest value so the whole
     series is presented on one scale. */
  function scaleOf(unit, v) {
    var a = Math.abs(v);
    if (unit === 'ns') {
      if (a >= 1e6) return { d: 1e6, u: 'ms' };
      if (a >= 1e3) return { d: 1e3, u: 'µs' };
      return { d: 1, u: 'ns' };
    }
    if (unit === 'B') {
      if (a >= 1024) return { d: 1024, u: 'KiB' };
      return { d: 1, u: 'B' };
    }
    if (unit === 'ev/s') {
      if (a >= 1e6) return { d: 1e6, u: 'M ev/s' };
      if (a >= 1e3) return { d: 1e3, u: 'k ev/s' };
      return { d: 1, u: 'ev/s' };
    }
    return { d: 1, u: unit || '' };
  }

  function fmtDate(ms) {
    var d = new Date(ms);
    if (isNaN(d.getTime())) return '—';
    return d.toISOString().slice(0, 16).replace('T', ' ') + ' UTC';
  }

  /* The action's tool is customSmallerIsBetter, which is right for every metric currently
     published — they all report ns, B or ms.

     The two ev/s throughput metrics used to be the exception, and they were mis-signalled in CI
     because the alert only ever looks for an increase: a throughput collapse read as an
     improvement. They are now published as ns_per_event instead, so nothing needs the inversion.
     This is kept because it costs nothing and makes the next ev/s metric correct by default. */
  function higherIsBetter(bench) {
    return bench.unit === 'ev/s' || /_ev_s$/.test(bench.name);
  }

  function sectionOf(name) {
    for (var i = 0; i < SECTIONS.length; i++) {
      if (name.indexOf(SECTIONS[i][0]) === 0) return SECTIONS[i][1];
    }
    return FALLBACK;
  }

  function shortName(name) {
    for (var i = 0; i < SECTIONS.length; i++) {
      if (name.indexOf(SECTIONS[i][0]) === 0) return name.slice(SECTIONS[i][0].length);
    }
    return name;
  }

  /* ───── tooltip ────────────────────────────────────────────────── */

  var tip = document.getElementById('tip');

  function showTip(anchor, point) {
    var b = point.bench;
    tip.textContent = '';

    var line = el('div');
    line.appendChild(el('span', 'sha', (point.commit.id || '').slice(0, 7)));
    line.appendChild(document.createTextNode('  '));
    line.appendChild(el('span', 'val', fmtValue(b.value) + ' ' + (b.unit || '')));
    tip.appendChild(line);

    tip.appendChild(el('div', 'when', fmtDate(point.date)));
    if (b.range) tip.appendChild(el('div', 'when', String(b.range)));
    if (b.extra) tip.appendChild(el('span', 'xtr', String(b.extra)));

    var r = anchor.getBoundingClientRect();
    var x = Math.min(Math.max(r.left + r.width / 2, 90), window.innerWidth - 90);
    tip.style.left = x + 'px';
    tip.style.top = r.top + 'px';
    tip.classList.add('on');
  }

  function hideTip() { tip.classList.remove('on'); }

  /* ───── sparkline ──────────────────────────────────────────────── */

  function sparkline(points) {
    var n = points.length;
    var vals = points.map(function (p) { return p.bench.value; });
    var min = Math.min.apply(null, vals);
    var max = Math.max.apply(null, vals);
    var span = (max - min) || 1;

    function px(i) { return n === 1 ? W / 2 : (i / (n - 1)) * W; }
    function py(v) { return max === min ? H / 2 : H - PAD - ((v - min) / span) * (H - 2 * PAD); }

    var root = svg('svg', {
      'class': 'bspark spark',
      viewBox: '0 0 ' + W + ' ' + H,
      preserveAspectRatio: 'none',
      role: 'img',
      'aria-label': n + ' measurements, latest ' + fmtValue(vals[n - 1])
    });

    var d = '';
    for (var i = 0; i < n; i++) d += (i ? ' L' : 'M') + px(i).toFixed(2) + ',' + py(vals[i]).toFixed(2);

    root.appendChild(svg('line', { 'class': 'axis', x1: 0, y1: H - 1, x2: W, y2: H - 1 }));
    if (n > 1) {
      root.appendChild(svg('path', { 'class': 'fill', d: d + ' L' + W + ',' + H + ' L0,' + H + ' Z' }));
    }
    root.appendChild(svg('path', { 'class': 'line', d: d }));

    /* One invisible band + one dot per measurement. The band is the hit
       target; hovering it reveals its dot and the tooltip. */
    for (var j = 0; j < n; j++) {
      (function (k) {
        var dot = svg('circle', { 'class': 'dot', cx: px(k).toFixed(2), cy: py(vals[k]).toFixed(2), r: 2.4 });
        var band = svg('rect', {
          'class': 'band',
          x: (n === 1 ? 0 : (k - 0.5) * (W / (n - 1))).toFixed(2),
          y: 0,
          width: (n === 1 ? W : W / (n - 1)).toFixed(2),
          height: H
        });
        var p = points[k];
        band.addEventListener('mouseenter', function () { dot.classList.add('on'); showTip(dot, p); });
        band.addEventListener('mouseleave', function () { dot.classList.remove('on'); hideTip(); });
        if (p.commit && p.commit.url) {
          band.addEventListener('click', function () {
            window.open(p.commit.url, '_blank', 'noopener');
          });
        }
        root.appendChild(band);
        root.appendChild(dot);
      })(j);
    }
    return root;
  }

  /* ───── one metric card ────────────────────────────────────────── */

  function card(name, points) {
    var n = points.length;
    var last = points[n - 1].bench;
    var hib = higherIsBetter(last);

    var c = el('div', 'bcard');
    c.appendChild(el('p', 'bname', shortName(name)));

    var sc = scaleOf(last.unit, last.value);
    var row = el('div', 'brow');
    var val = el('p', 'bval');
    val.appendChild(document.createTextNode(fmtValue(last.value / sc.d)));
    if (sc.u) val.appendChild(el('span', 'unit', sc.u));
    row.appendChild(val);

    var prev = n > 1 ? points[n - 2].bench.value : null;
    var delta = el('span', 'bdelta flat', '—');
    if (prev != null && prev !== 0) {
      var pct = ((last.value - prev) / Math.abs(prev)) * 100;
      if (Math.abs(pct) < 0.05) {
        delta.className = 'bdelta flat';
        delta.textContent = '±0%';
      } else {
        var improved = hib ? pct > 0 : pct < 0;
        delta.className = 'bdelta ' + (improved ? 'good' : 'bad');
        delta.textContent = (pct > 0 ? '▲' : '▼') + ' ' + Math.abs(pct).toFixed(1) + '%';
      }
      delta.title = 'vs previous commit (' + fmtValue(prev) + ' ' + (last.unit || '') + ' exact)';
    }
    row.appendChild(delta);
    c.appendChild(row);

    c.appendChild(sparkline(points));

    var meta = el('div', 'bmeta');
    meta.appendChild(el('span', null, n + (n === 1 ? ' run' : ' runs')));
    meta.appendChild(el('span', hib ? 'hib' : null, hib ? '↑ higher is better' : 'lower is better'));
    c.appendChild(meta);

    return c;
  }

  /* ───── panels ─────────────────────────────────────────────────── */

  function panel(title, right) {
    var p = el('div', 'panel');
    p.appendChild(el('span', 'br-tr'));
    p.appendChild(el('span', 'br-bl'));
    var head = el('div', 'panel-head');
    head.appendChild(el('span', null, title));
    head.appendChild(el('span', 'seq', right || ''));
    p.appendChild(head);
    return p;
  }

  function summaryCell(label, value, note) {
    var m = el('div', 'metric');
    m.appendChild(el('p', 'label', label));
    var v = el('p', 'value');
    v.appendChild(document.createTextNode(value));
    m.appendChild(v);
    if (note) m.appendChild(el('p', 'note', note));
    return m;
  }

  function renderEmpty() {
    var host = document.getElementById('sections');
    var p = panel('Benchmarks', 'no data');
    var body = el('div', 'empty');
    body.appendChild(el('strong', null, 'No benchmark data on this page yet.'));
    var line = el('p');
    line.appendChild(document.createTextNode('Expected '));
    line.appendChild(el('code', null, 'window.BENCHMARK_DATA'));
    line.appendChild(document.createTextNode(' from '));
    line.appendChild(el('code', null, './data.js'));
    line.appendChild(document.createTextNode('. It is written by the benchmark workflow on each push to main.'));
    body.appendChild(line);
    p.appendChild(body);
    host.appendChild(p);
  }

  /* ───── main ───────────────────────────────────────────────────── */

  function init() {
    var data = window.BENCHMARK_DATA;
    var entries = (data && data.entries && data.entries.Benchmark) || [];

    if (!entries.length) { renderEmpty(); return; }

    var sorted = entries.slice().sort(function (a, b) { return a.date - b.date; });

    /* name → chronological list of measurements */
    var series = new Map();
    sorted.forEach(function (e) {
      (e.benches || []).forEach(function (b) {
        if (!series.has(b.name)) series.set(b.name, []);
        series.get(b.name).push({ commit: e.commit, date: e.date, bench: b });
      });
    });

    /* section title → [name, points][] */
    var buckets = new Map();
    Array.from(series.keys()).sort().forEach(function (name) {
      var s = sectionOf(name);
      if (!buckets.has(s)) buckets.set(s, []);
      buckets.get(s).push([name, series.get(name)]);
    });

    var order = SECTIONS.map(function (s) { return s[1]; }).concat([FALLBACK])
      .filter(function (t) { return buckets.has(t); });

    /* ── status bar + footer ── */
    document.getElementById('commit-count').textContent =
      sorted.length + (sorted.length === 1 ? ' commit' : ' commits');
    document.getElementById('tool-label').textContent = sorted[sorted.length - 1].tool || 'benchmark';
    document.getElementById('last-update').textContent =
      'last update · ' + fmtDate(data.lastUpdate || sorted[sorted.length - 1].date);

    /* ── summary ──
       Counting metrics that merely moved the wrong way is noise: these run
       on shared GitHub runners, where run-to-run variance routinely swings a
       metric tens of percent. The number worth surfacing is the one CI acts
       on — a metric more than 2x its previous value. */
    var breaches = 0;
    series.forEach(function (points) {
      if (points.length < 2) return;
      var last = points[points.length - 1].bench;
      var prev = points[points.length - 2].bench.value;
      if (!prev || !last.value) return;
      var ratio = higherIsBetter(last) ? prev / last.value : last.value / prev;
      if (ratio > 2) breaches++;
    });

    var first = sorted[0].commit.id ? sorted[0].commit.id.slice(0, 7) : '—';
    var lastSha = sorted[sorted.length - 1].commit.id ? sorted[sorted.length - 1].commit.id.slice(0, 7) : '—';

    var sp = panel('Suite summary', first + ' → ' + lastSha);
    var grid = el('div', 'metrics');
    grid.appendChild(summaryCell('Metrics tracked', String(series.size), 'one series per bench, appended each run'));
    grid.appendChild(summaryCell('Subsystems', String(order.length), 'grouped by metric-name prefix'));
    grid.appendChild(summaryCell('Commits measured', String(sorted.length), 'one bench run per push to main'));
    grid.appendChild(summaryCell('Alert breaches', String(breaches), 'metrics past the 200% CI threshold'));
    sp.appendChild(grid);
    var sfoot = el('div', 'panel-foot');
    sfoot.appendChild(el('span', null, 'github-action-benchmark'));
    sfoot.appendChild(el('span', null, fmtDate(data.lastUpdate)));
    sp.appendChild(sfoot);
    document.getElementById('summary').appendChild(sp);

    /* ── jump chips ── */
    var jump = document.getElementById('jump');
    order.forEach(function (title) {
      var a = el('a', null);
      a.href = '#' + slug(title);
      a.appendChild(el('span', null, title));
      a.appendChild(el('span', 'n', String(buckets.get(title).length)));
      jump.appendChild(a);
    });

    /* ── one panel per section ── */
    var host = document.getElementById('sections');
    order.forEach(function (title, i) {
      var items = buckets.get(title);
      var p = panel(title, items.length + (items.length === 1 ? ' metric' : ' metrics'));
      p.id = slug(title);
      p.classList.add('section');
      p.style.animationDelay = Math.min(0.10 + i * 0.03, 0.5) + 's';
      var g = el('div', 'bench-grid');
      items.forEach(function (pair) { g.appendChild(card(pair[0], pair[1])); });
      p.appendChild(g);
      host.appendChild(p);
    });

    window.addEventListener('scroll', hideTip, { passive: true });
  }

  if (document.readyState === 'loading') {
    document.addEventListener('DOMContentLoaded', init);
  } else {
    init();
  }
})();
