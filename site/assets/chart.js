/* ═══════════════════════════════════════════════════════════════════
   AlgoStream — inline SVG charting.

   The original design called for "interactive charting with D3.js integration". This is hand-rolled SVG
   instead, and the substitution is deliberate: the site is strictly zero-external-request, the
   benchmark dashboard already draws its sparklines this way, and vendoring ~280KB of third-party
   JavaScript into a repository that hand-rolls its own RNG and numerics would be out of character
   for the sake of axes we can compute in twenty lines.

   Everything here draws into an existing <svg> and styles via the shared CSS custom properties,
   so charts inherit the site's palette rather than carrying their own.
   ═══════════════════════════════════════════════════════════════════ */
(function (global) {
  'use strict';

  var NS = 'http://www.w3.org/2000/svg';

  function el(tag, attrs) {
    var n = document.createElementNS(NS, tag);
    for (var k in attrs) if (Object.prototype.hasOwnProperty.call(attrs, k)) {
      n.setAttribute(k, attrs[k]);
    }
    return n;
  }

  function clear(svg) {
    while (svg.firstChild) svg.removeChild(svg.firstChild);
  }

  /* Format a nanosecond duration for an axis label. Latency spans nine orders of magnitude, so a
     fixed unit is useless. */
  function fmtNs(ns) {
    var v = Number(ns);
    if (!isFinite(v)) return '—';
    if (v >= 1e9) return (v / 1e9).toFixed(2) + ' s';
    if (v >= 1e6) return (v / 1e6).toFixed(2) + ' ms';
    if (v >= 1e3) return (v / 1e3).toFixed(1) + ' µs';
    return Math.round(v) + ' ns';
  }

  function fmtNum(v) {
    if (v === null || v === undefined || !isFinite(v)) return '—';
    var a = Math.abs(v);
    if (a >= 1e9) return (v / 1e9).toFixed(2) + 'B';
    if (a >= 1e6) return (v / 1e6).toFixed(2) + 'M';
    if (a >= 1e3) return (v / 1e3).toFixed(1) + 'k';
    if (Number.isInteger(v)) return String(v);
    if (a >= 1) return v.toFixed(2);
    return v.toPrecision(3);
  }

  /* ───── line / area ─────────────────────────────────────────────
     points: array of [x, y]. Options:
       yMin/yMax  fix the domain (otherwise derived, padded 6%)
       band       { value, label } draws a horizontal reference line — the 5ms SLA marker
       area       fill under the line
       fmtY       label formatter for the axis
  */
  function line(svg, points, opts) {
    opts = opts || {};
    clear(svg);
    var W = 100, H = 100;                 /* viewBox units; CSS controls real size */
    svg.setAttribute('viewBox', '0 0 ' + W + ' ' + H);
    svg.setAttribute('preserveAspectRatio', 'none');

    if (!points || points.length === 0) {
      svg.appendChild(el('line', { x1: 0, y1: H - 1, x2: W, y2: H - 1, class: 'ch-axis' }));
      return;
    }

    var padTop = 6, padBot = 10;
    var ys = points.map(function (p) { return p[1]; }).filter(isFinite);
    var lo = opts.yMin !== undefined ? opts.yMin : Math.min.apply(null, ys);
    var hi = opts.yMax !== undefined ? opts.yMax : Math.max.apply(null, ys);
    if (opts.band && isFinite(opts.band.value)) {
      lo = Math.min(lo, opts.band.value);
      hi = Math.max(hi, opts.band.value);
    }
    if (lo === hi) { lo -= 1; hi += 1; }
    var pad = (hi - lo) * 0.06;
    lo -= pad; hi += pad;

    var n = points.length;
    function px(i) { return n === 1 ? W / 2 : (i / (n - 1)) * W; }
    function py(v) { return H - padBot - ((v - lo) / (hi - lo)) * (H - padTop - padBot); }

    svg.appendChild(el('line', { x1: 0, y1: H - padBot, x2: W, y2: H - padBot, class: 'ch-axis' }));

    if (opts.band && isFinite(opts.band.value)) {
      var by = py(opts.band.value);
      svg.appendChild(el('line', { x1: 0, y1: by, x2: W, y2: by, class: 'ch-band' }));
    }

    var d = '';
    for (var i = 0; i < n; i++) {
      var y = isFinite(points[i][1]) ? py(points[i][1]) : py(lo);
      d += (i ? ' L' : 'M') + px(i).toFixed(2) + ',' + y.toFixed(2);
    }
    if (opts.area && n > 1) {
      svg.appendChild(el('path', {
        class: 'ch-fill',
        d: d + ' L' + W + ',' + (H - padBot) + ' L0,' + (H - padBot) + ' Z'
      }));
    }
    svg.appendChild(el('path', { class: 'ch-line', d: d }));
    return { lo: lo, hi: hi };
  }

  /* ───── multiple series on a shared time axis ───────────────────
     series: [{ points: [[x, y], ...], cls: 'ch-line-a' }]

     Separate from line() rather than an option on it, for one reason: line() places points by
     INDEX, which is right for a streaming ring where every sample is one tick apart, and wrong the
     moment two series are drawn together. Two live strategies sample on their own timers, so index
     i in one is not the same instant as index i in the other; plotting both by index would show
     them diverging or converging purely from a difference in sample count.

     Here x is a real coordinate and both series share one domain, so a point's horizontal position
     means the same thing in every series. Y is shared too — comparing curves on separate y scales
     would make a flat line and a volatile one look identical.
  */
  function lines(svg, series, opts) {
    opts = opts || {};
    clear(svg);
    var W = 100, H = 100, padTop = 6, padBot = 10;
    svg.setAttribute('viewBox', '0 0 ' + W + ' ' + H);
    svg.setAttribute('preserveAspectRatio', 'none');

    var all = [];
    (series || []).forEach(function (s) {
      (s.points || []).forEach(function (p) {
        if (isFinite(p[0]) && isFinite(p[1])) all.push(p);
      });
    });
    if (all.length === 0) {
      svg.appendChild(el('line', { x1: 0, y1: H - 1, x2: W, y2: H - 1, class: 'ch-axis' }));
      return null;
    }

    var xs = all.map(function (p) { return p[0]; });
    var ys = all.map(function (p) { return p[1]; });
    var x0 = Math.min.apply(null, xs), x1 = Math.max.apply(null, xs);
    var lo = Math.min.apply(null, ys), hi = Math.max.apply(null, ys);
    if (x0 === x1) { x0 -= 1; x1 += 1; }
    if (lo === hi) { lo -= 1; hi += 1; }
    var pad = (hi - lo) * 0.06;
    lo -= pad; hi += pad;

    function px(x) { return ((x - x0) / (x1 - x0)) * W; }
    function py(v) { return H - padBot - ((v - lo) / (hi - lo)) * (H - padTop - padBot); }

    svg.appendChild(el('line', { x1: 0, y1: H - padBot, x2: W, y2: H - padBot, class: 'ch-axis' }));

    (series || []).forEach(function (s) {
      var pts = (s.points || []).filter(function (p) { return isFinite(p[0]) && isFinite(p[1]); });
      if (!pts.length) return;
      var d = '';
      for (var i = 0; i < pts.length; i++) {
        d += (i ? ' L' : 'M') + px(pts[i][0]).toFixed(2) + ',' + py(pts[i][1]).toFixed(2);
      }
      svg.appendChild(el('path', { class: s.cls || 'ch-line', d: d }));
    });
    return { lo: lo, hi: hi, x0: x0, x1: x1 };
  }

  /* ───── horizontal bars ─────────────────────────────────────────
     rows: [{ label, value, max, tone }] — tone is 'ok' | 'warn' | 'bad'
  */
  function bars(container, rows) {
    container.textContent = '';
    rows.forEach(function (r) {
      var wrap = document.createElement('div');
      wrap.className = 'ch-bar';
      var lab = document.createElement('span');
      lab.className = 'ch-bar-label';
      lab.textContent = r.label;
      var track = document.createElement('span');
      track.className = 'ch-bar-track';
      var fill = document.createElement('span');
      fill.className = 'ch-bar-fill' + (r.tone ? ' ' + r.tone : '');
      var frac = r.max > 0 ? Math.max(0, Math.min(1, r.value / r.max)) : 0;
      fill.style.width = (frac * 100).toFixed(1) + '%';
      track.appendChild(fill);
      var val = document.createElement('span');
      val.className = 'ch-bar-value';
      val.textContent = r.display !== undefined ? r.display : fmtNum(r.value);
      wrap.appendChild(lab);
      wrap.appendChild(track);
      wrap.appendChild(val);
      container.appendChild(wrap);
    });
  }

  /* A bounded ring for streaming series — the dashboard runs for days and must not grow. */
  function Ring(capacity) {
    this.cap = capacity;
    this.data = [];
  }
  Ring.prototype.push = function (x, y) {
    this.data.push([x, y]);
    if (this.data.length > this.cap) this.data.splice(0, this.data.length - this.cap);
  };
  Ring.prototype.points = function () { return this.data; };
  Ring.prototype.last = function () {
    return this.data.length ? this.data[this.data.length - 1][1] : null;
  };

  global.Chart = { line: line, lines: lines, bars: bars, Ring: Ring, fmtNs: fmtNs, fmtNum: fmtNum, clear: clear };
})(window);
