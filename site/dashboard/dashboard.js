/* ═══════════════════════════════════════════════════════════════════
   AlgoStream dashboard.

   Consumes the daemon's /events stream (Server-Sent Events) and re-renders on each frame. Falls
   back to polling /api/telemetry + /api/strategies if EventSource is unavailable or the stream
   keeps failing, so the page still works behind a proxy that buffers text/event-stream.
   ═══════════════════════════════════════════════════════════════════ */
(function () {
  'use strict';

  /* Rendering discipline: innerHTML is only ever assigned a *static literal* skeleton. Every value
     that came from the daemon goes in through textContent, and every class through classList — so
     a symbol or strategy tag containing markup cannot become markup. */

  var C = window.Chart;
  var CAP = 240;                    /* ~60s of history at 4 Hz */
  var latency = new C.Ring(CAP);
  var throughput = new C.Ring(CAP);
  var nav = new C.Ring(CAP);
  var frames = 0;

  var $ = function (id) { return document.getElementById(id); };

  function text(node, s) { if (node.textContent !== s) node.textContent = s; }

  function statusClass(st) {
    return st && st.state ? st.state : 'ok';
  }

  /* ───── rendering ───────────────────────────────────────────── */

  function renderSystem(t) {
    var st = t.overall || { state: 'ok' };
    var pill = $('overall-pill');
      pill.className = 'pill ' + statusClass(st);
      pill.innerHTML = '';
      var dot = document.createElement('span'); dot.className = 'dot';
      pill.appendChild(dot);
      pill.appendChild(document.createTextNode(st.state + (st.reason ? ' · ' + st.reason : '')));

    var lat = t.latency || {}, e2e = lat.end_to_end || {}, bus = t.bus || {};
    /* Latency is [now - event.timestamp_ns], a delivery time only when the source is live. A
       replayed log — and the recorded demo frame, which came from one — carries the timestamps the
       events were recorded with, so the figure is the age of the log and must not be coloured as a
       breach. */
    var replaying = SOURCE === 'replay' || SOURCE === 'demo';
    var slaBad = !replaying && Number(e2e.p99_ns) > Number(lat.sla_ns);
    var stats = [
      { k: 'p99 latency', v: C.fmtNs(e2e.p99_ns), cls: replaying ? 'plain' : (slaBad ? 'bad' : 'good'),
        n: replaying ? 'age of the recorded log' : 'sla ' + C.fmtNs(lat.sla_ns) },
      { k: 'p50 latency', v: C.fmtNs(e2e.p50_ns), cls: 'plain', n: 'median' },
      { k: 'throughput', v: C.fmtNum(bus.events_per_sec), cls: '', n: 'events/sec' },
      { k: 'dispatched', v: C.fmtNum(Number(bus.dispatched)), cls: 'plain', n: 'since start' },
      { k: 'dropped', v: C.fmtNum(Number(bus.dropped)), cls: Number(bus.dropped) > 0 ? 'bad' : 'good',
        n: 'publish overflow' },
      { k: 'handler errors', v: C.fmtNum(Number(bus.handler_errors)),
        cls: Number(bus.handler_errors) > 0 ? 'bad' : 'good', n: 'subscriber exceptions' },
      { k: 'queue depth', v: C.fmtNum(bus.depth), cls: 'plain', n: bus.subscribers + ' subscribers' },
      { k: 'sla breaches',
        v: replaying ? 'n/a' : (Number(lat.sla_violation_pct) || 0).toFixed(2) + '%',
        cls: replaying ? 'plain' : (Number(lat.sla_violation_pct) > 1 ? 'bad' : 'good'),
        n: replaying ? 'source is not live' : C.fmtNum(Number(lat.sla_violations)) }
    ];
    var host = $('system-stats');
      host.innerHTML = '';
      stats.forEach(function (s) {
        var d = document.createElement('div'); d.className = 'stat';
        d.innerHTML = '<p class="k"></p><p class="v"></p><p class="n"></p>';
        d.querySelector('.k').textContent = s.k;
        var v = d.querySelector('.v');
          v.textContent = s.v;
          if (s.cls) v.classList.add(s.cls);
        d.querySelector('.n').textContent = s.n;
        host.appendChild(d);
      });

    text($('uptime'), 'up ' + fmtDuration(Number(t.uptime_ns)) + ' · ' + SOURCE);
    text($('lat-note'),
      replaying ? 'log age, not a delivery time' : 'p99 vs 5 ms SLA');
  }

  function fmtDuration(ns) {
    var s = ns / 1e9;
    if (s < 60) return s.toFixed(0) + 's';
    if (s < 3600) return Math.floor(s / 60) + 'm ' + Math.floor(s % 60) + 's';
    return Math.floor(s / 3600) + 'h ' + Math.floor((s % 3600) / 60) + 'm';
  }

  function renderCharts(t) {
    var lat = t.latency || {}, e2e = lat.end_to_end || {}, bus = t.bus || {};
      latency.push(frames, Number(e2e.p99_ns) || 0);
      throughput.push(frames, Number(bus.events_per_sec) || 0);

      var r = C.line($('lat-chart'), latency.points(), {
        area: true, band: { value: Number(lat.sla_ns) }
      });
      if (r) { text($('lat-lo'), C.fmtNs(r.lo)); text($('lat-hi'), C.fmtNs(r.hi)); }

      var r2 = C.line($('tp-chart'), throughput.points(), { area: true, yMin: 0 });
      if (r2) { text($('tp-lo'), C.fmtNum(r2.lo) + ' ev/s'); text($('tp-hi'), C.fmtNum(r2.hi) + ' ev/s'); }

      var depth = bus.depth_per_band || [];
      var names = ['critical', 'high', 'normal', 'low'];
      var maxDepth = Math.max(1, Math.max.apply(null, depth.concat([1])));
      C.bars($('bands'), depth.map(function (d, i) {
        return {
          label: names[i] || String(i),
          value: d,
          max: maxDepth,
          tone: i === 0 && d > 0 ? 'bad' : (d > maxDepth * 0.7 ? 'warn' : 'ok')
        };
      }));
  }

  function renderComponents(t) {
    var comps = t.components || [];
    var tbl = $('components');
      text($('comp-count'), comps.length + (comps.length === 1 ? ' subsystem' : ' subsystems'));
      tbl.innerHTML = '<thead><tr><th>subsystem</th><th>status</th><th>metrics</th></tr></thead>';
      var tb = document.createElement('tbody');
      if (comps.length === 0) {
        tb.innerHTML = '<tr><td colspan="3" class="empty-note">no subsystems registered</td></tr>';
      } else {
        comps.forEach(function (c) {
          var tr = document.createElement('tr');
          var keys = Object.keys(c.metrics || {});
          var summary = keys.slice(0, 3).map(function (k) {
            return k + '=' + C.fmtNum(c.metrics[k]);
          }).join('  ');
          tr.innerHTML = '<td></td><td></td><td></td>';
          tr.children[0].textContent = c.name;
          tr.children[1].textContent = (c.status && c.status.state) || 'ok';
          tr.children[1].className = c.status && c.status.state === 'ok' ? 'pos'
            : (c.status && c.status.state === 'failed' ? 'neg' : '');
          tr.children[2].textContent = summary || '—';
          tb.appendChild(tr);
        });
      }
      tbl.appendChild(tb);
  }

  function renderRuntime(rt) {
    nav.push(frames, Number(rt.total_nav) || 0);
    C.line($('nav-chart'), nav.points(), { area: true });

    var insts = rt.instances || [];
      text($('strat-count'), insts.length + (insts.length === 1 ? ' instance' : ' instances'));

      var totals = insts.reduce(function (a, i) {
        a.realized += i.realized_pnl; a.unrealized += i.unrealized_pnl;
        a.gross += i.gross_exposure; a.fills += i.counters.fills;
        return a;
      }, { realized: 0, unrealized: 0, gross: 0, fills: 0 });

      var pstats = [
        { k: 'nav', v: C.fmtNum(rt.total_nav), cls: '' },
        { k: 'realized p&l', v: C.fmtNum(totals.realized), cls: totals.realized >= 0 ? 'good' : 'bad' },
        { k: 'unrealized p&l', v: C.fmtNum(totals.unrealized), cls: totals.unrealized >= 0 ? 'good' : 'bad' },
        { k: 'gross exposure', v: C.fmtNum(totals.gross), cls: 'plain' },
        { k: 'fills', v: C.fmtNum(totals.fills), cls: 'plain' },
        { k: 'events', v: C.fmtNum(rt.events), cls: 'plain' }
      ];
      var host = $('portfolio-stats');
        host.innerHTML = '';
        pstats.forEach(function (s) {
          var d = document.createElement('div'); d.className = 'stat';
          d.innerHTML = '<p class="k"></p><p class="v"></p>';
          d.querySelector('.k').textContent = s.k;
          var v = d.querySelector('.v');
            v.textContent = s.v;
            if (s.cls) v.classList.add(s.cls);
          host.appendChild(d);
        });

      renderStrategies(insts);
      renderPositions(insts);
      renderFills(insts);
  }

  function renderStrategies(insts) {
    var host = $('strategies');
      host.innerHTML = '';
      if (insts.length === 0) {
        host.innerHTML = '<div class="empty-note">no strategies running — start the daemon without --no-strategy</div>';
        return;
      }
      insts.forEach(function (i) {
        var d = document.createElement('div');
        d.className = 'strat';
        var running = i.lifecycle === 'running';
        var stopped = i.lifecycle === 'stopped';
        d.innerHTML =
          '<div class="strat-head">' +
            '<div><div class="strat-name"></div><div class="strat-sub"></div></div>' +
            '<div class="ctl">' +
              '<button data-a="pause">pause</button>' +
              '<button data-a="resume">resume</button>' +
              '<button data-a="stop">stop</button>' +
            '</div>' +
          '</div><div class="strat-metrics"></div>';
        d.querySelector('.strat-name').textContent = i.strategy_id + ' — ' + i.name + ' v' + i.version;
        d.querySelector('.strat-sub').textContent = i.lifecycle + ' · alloc ' + C.fmtNum(i.allocation);

        var m = d.querySelector('.strat-metrics');
        [['nav', C.fmtNum(i.nav)], ['realized', C.fmtNum(i.realized_pnl)],
         ['unrealized', C.fmtNum(i.unrealized_pnl)], ['leverage', C.fmtNum(i.leverage)],
         ['working', C.fmtNum(i.working_orders)], ['submitted', C.fmtNum(i.counters.submitted)],
         ['fills', C.fmtNum(i.counters.fills)], ['risk rejects', C.fmtNum(i.counters.rejected_by_risk)]
        ].forEach(function (p) {
          var e = document.createElement('div');
          e.innerHTML = '<span></span><b></b>';
          e.querySelector('span').textContent = p[0];
          e.querySelector('b').textContent = p[1];
          m.appendChild(e);
        });

        /* Lifecycle decides what is *applicable*; the key's scopes decide what is *permitted*. A
           read-only key disables all three rather than letting the operator click through to a 403. */
        var btns = d.querySelectorAll('.ctl button');
        btns[0].disabled = !running || !canControl;
        btns[1].disabled = i.lifecycle !== 'paused' || !canControl;
        btns[2].disabled = stopped || !canControl;
        if (!canControl) {
          Array.prototype.forEach.call(btns, function (b) { b.title = 'this key is read-only'; });
        }
        Array.prototype.forEach.call(btns, function (b) {
          b.addEventListener('click', function () { control(i.strategy_id, b.getAttribute('data-a')); });
        });
        host.appendChild(d);
      });
  }

  function renderPositions(insts) {
    var rows = [];
    insts.forEach(function (i) {
      (i.positions || []).forEach(function (p) { rows.push([i.strategy_id, p]); });
    });
    var tbl = $('positions');
      text($('pos-count'), rows.length + (rows.length === 1 ? ' position' : ' positions'));
      tbl.innerHTML = '<thead><tr><th>strategy</th><th>symbol</th><th>qty</th><th>avg</th><th>value</th><th>unrealized</th></tr></thead>';
      var tb = document.createElement('tbody');
      if (rows.length === 0) {
        tb.innerHTML = '<tr><td colspan="6" class="empty-note">flat</td></tr>';
      } else {
        rows.forEach(function (r) {
          var p = r[1];
          var tr = document.createElement('tr');
          tr.innerHTML = '<td></td><td></td><td></td><td></td><td></td><td></td>';
          tr.children[0].textContent = r[0];
          tr.children[1].textContent = p.symbol;
          tr.children[2].textContent = C.fmtNum(p.quantity);
          tr.children[3].textContent = C.fmtNum(p.average_price);
          tr.children[4].textContent = C.fmtNum(p.market_value);
          tr.children[5].textContent = C.fmtNum(p.unrealized_pnl);
          tr.children[5].className = p.unrealized_pnl >= 0 ? 'pos' : 'neg';
          tb.appendChild(tr);
        });
      }
      tbl.appendChild(tb);
  }

  function renderFills(insts) {
    var rows = [];
    insts.forEach(function (i) {
      (i.recent_fills || []).forEach(function (f) { rows.push([i.strategy_id, f]); });
    });
    rows.sort(function (a, b) { return Number(b[1].ts_ns) - Number(a[1].ts_ns); });
    rows = rows.slice(0, 25);

    var tbl = $('fills');
      text($('fill-count'), rows.length ? 'newest ' + rows.length : 'none');
      tbl.innerHTML = '<thead><tr><th>symbol</th><th>side</th><th>qty</th><th>price</th><th>fee</th><th>liq</th></tr></thead>';
      var tb = document.createElement('tbody');
      if (rows.length === 0) {
        tb.innerHTML = '<tr><td colspan="6" class="empty-note">no fills yet</td></tr>';
      } else {
        rows.forEach(function (r) {
          var f = r[1];
          var tr = document.createElement('tr');
          tr.innerHTML = '<td></td><td></td><td></td><td></td><td></td><td></td>';
          tr.children[0].textContent = f.symbol;
          tr.children[1].textContent = f.side;
          tr.children[1].className = /buy/i.test(f.side) ? 'pos' : 'neg';
          tr.children[2].textContent = C.fmtNum(f.quantity);
          tr.children[3].textContent = C.fmtNum(f.price);
          tr.children[4].textContent = C.fmtNum(f.commission);
          tr.children[5].textContent = f.liquidity;
          tb.appendChild(tr);
        });
      }
      tbl.appendChild(tb);
  }

  function renderAlerts(t) {
    var alerts = t.alerts || [];
    var host = $('alerts');
      text($('alert-count'), alerts.length ? alerts.length + ' active' : 'none');
      host.innerHTML = '';
      if (alerts.length === 0) {
        host.innerHTML = '<div class="empty-note">no active alerts</div>';
        return;
      }
      alerts.forEach(function (a) {
        var d = document.createElement('div');
        d.className = 'alert-row ' + a.severity;
        d.innerHTML = '<span class="alert-code"></span><span class="alert-msg"></span><span class="alert-count"></span>';
        d.querySelector('.alert-code').textContent = a.code;
        d.querySelector('.alert-msg').textContent = a.message;
        d.querySelector('.alert-count').textContent = '×' + a.count;
        host.appendChild(d);
      });
  }

  var SOURCE = 'live';

  function render(payload) {
    frames++;
    try {
      if (payload.source) SOURCE = payload.source;
      if (payload.telemetry) { renderSystem(payload.telemetry); renderCharts(payload.telemetry);
                               renderComponents(payload.telemetry); renderAlerts(payload.telemetry); }
      if (payload.runtime) renderRuntime(payload.runtime);
      text($('last-update'), new Date().toLocaleTimeString());
    } catch (e) {
      /* A malformed frame must not kill the stream; the next one may be fine. */
      if (window.console) console.error('render failed', e);
    }
  }

  /* ───── credential ────────────────────────────────────────────

     sessionStorage rather than localStorage: the key dies with the tab. The page is same-origin so
     no other site can read it, and nothing the daemon sends is ever turned into markup, so there is
     no XSS path to it either.

     The key travels only in an Authorization header — never a query string, and never a cookie.
     That is what makes a control action forgeable only by this page: a cross-origin fetch setting
     Authorization triggers a CORS preflight the daemon does not answer. A cookie would be attached
     automatically and hand that property away.
  */

  var KEY_ITEM = 'algostream.key';

  function apiKey() {
    try { return window.sessionStorage.getItem(KEY_ITEM) || ''; } catch (e) { return ''; }
  }

  function setApiKey(v) {
    try { if (v) window.sessionStorage.setItem(KEY_ITEM, v); else window.sessionStorage.removeItem(KEY_ITEM); }
    catch (e) { /* private mode; the key simply will not persist */ }
  }

  function authHeaders(extra) {
    var h = extra || {};
    var k = apiKey();
    if (k) h['Authorization'] = 'Bearer ' + k;
    return h;
  }

  /* Every call goes through here so no request can quietly forget the credential. */
  function api(path, opts) {
    opts = opts || {};
    opts.headers = authHeaders(opts.headers);
    return fetch(path, opts).then(function (r) {
      if (r.status === 401) {
        promptForKey(apiKey() ? 'That key was not accepted.' : 'This daemon requires an API key.');
      }
      return r;
    });
  }

  function promptForKey(message) {
    var el = document.getElementById('key-prompt');
    if (!el) return;
    el.hidden = false;
    var msg = document.getElementById('key-prompt-msg');
    if (msg && message) msg.textContent = message;
    var input = document.getElementById('key-input');
    if (input) input.focus();
  }

  /* Grey out the control buttons when the key cannot use them, rather than letting the operator
     click through to a 403. */
  /* Permitted until told otherwise, so an unauthenticated daemon — the make dash case — behaves
     exactly as it does without a keystore. */
  var canControl = true;

  function applyScopes(scopes) {
    canControl = scopes === null || /control/.test(scopes || '');
    var who = document.getElementById('whoami');
    if (who) who.textContent = scopes ? scopes : '';
  }

  function refreshWhoami() {
    if (!apiKey()) { applyScopes(null); return; }   /* no key: unauthenticated daemon, or not yet asked */
    api('/api/whoami')
      .then(function (r) { return r.ok ? r.json() : null; })
      .then(function (j) { if (j) applyScopes(j.scopes); })
      .catch(function () { /* leave the controls as they are */ });
  }

  /* ───── control ─────────────────────────────────────────────── */

  function control(id, action) {
    api('/api/strategies/' + encodeURIComponent(id) + '/' + action, { method: 'POST' })
      .then(function (r) { return r.json(); })
      .then(function (j) { if (j.error && window.console) console.error(j.error); })
      .catch(function (e) { if (window.console) console.error(e); });
  }

  /* ───── transport ─────────────────────────────────────────────

     Three modes, chosen by one probe rather than by waiting for retries to fail:

       live   a daemon answered /api/health  ->  SSE stream, polling as a fallback
       demo   nothing answered               ->  render a recorded frame from ./demo.json

     The probe matters because the demo is served from GitHub Pages, where /api and /events are
     plain 404s. Without it the page would spend seconds retrying a stream that cannot exist
     before showing anything at all. */

  function setConn(state, label) {
    var el = $('conn-text');
      text(el, label);
      el.className = state === 'live' ? '' : 'disconnected';
  }

  var pollTimer = null;

  function startPolling() {
    if (pollTimer) return;
    setConn('poll', 'polling');
    pollTimer = setInterval(function () {
      Promise.all([
        api('/api/telemetry').then(function (r) { return r.json(); }),
        api('/api/strategies').then(function (r) { return r.json(); })
      ])
        .then(function (xs) { render({ telemetry: xs[0], runtime: xs[1] }); })
        .catch(function () { setConn('down', 'disconnected'); });
    }, 1000);
  }

  function startStream() {
    if (!window.EventSource) { startPolling(); return; }
    var failures = 0;

    /* EventSource cannot set request headers, so the stream uses a single-use ticket minted with
       the bearer key. It must be minted per open() — including every reconnect — because redeeming
       one twice is a 401 by design. Without a keystore the daemon returns an empty ticket and the
       query parameter is simply ignored. */
    var open = function () {
      var proceed = function (ticket) {
        var url = ticket ? '/events?ticket=' + encodeURIComponent(ticket) : '/events';
        attach(new EventSource(url));
      };
      if (!apiKey()) { proceed(''); return; }
      api('/api/stream-ticket', { method: 'POST' })
        .then(function (r) { return r.ok ? r.json() : null; })
        .then(function (j) { proceed(j && j.ticket ? j.ticket : ''); })
        .catch(function () { proceed(''); });
    };

    var attach = function (es) {
      es.onopen = function () { failures = 0; setConn('live', 'live'); };
      es.onmessage = function (ev) {
        try { render(JSON.parse(ev.data)); } catch (e) { /* one bad frame must not kill the stream */ }
      };
      es.onerror = function () {
        es.close();
        failures++;
        setConn('down', 'reconnecting');
        /* EventSource reconnects itself, but a proxy that buffers event-streams makes it fail
           forever; after a few tries fall back to polling rather than showing a dead page. */
        if (failures >= 4) { startPolling(); return; }
        setTimeout(open, Math.min(1000 * failures, 5000));
      };
    };
    open();
  }

  function startDemo() {
    var banner = document.getElementById('demo-banner');
      if (banner) banner.hidden = false;
      setConn('demo', 'recorded');
      fetch('./demo.json')
        .then(function (r) { if (!r.ok) throw new Error('no fixture'); return r.json(); })
        .then(function (frame) {
          render(frame);
          /* Re-render on a timer so the charts fill their axis instead of showing a single point.
             The values are identical every frame; this is recorded data and the banner says so. */
          setInterval(function () { render(frame); }, 1000);
        })
        .catch(function () { setConn('down', 'no daemon, no demo fixture'); });
  }

  function begin() {
    /* On Pages this 404s instantly; against a daemon it answers instantly. Either way the page
       decides well inside the timeout. */
    var settled = false;
    var decide = function (live) {
      if (settled) return;
      settled = true;
      if (live) startStream(); else startDemo();
    };
      setTimeout(function () { decide(false); }, 1500);
      /* /api/health stays public precisely so this probe works. If it needed a credential, a live
         daemon would 401 here and the page would render the recorded demo — a silent, confusing
         regression. auth_required is how the page knows to ask for a key rather than guess. */
      fetch('/api/health')
        .then(function (r) {
          if (!r.ok) { decide(false); return null; }
          return r.json().catch(function () { return null; });
        })
        .then(function (j) {
          if (j && j.auth_required && !apiKey()) {
            /* Deliberately do not start a transport here. Both the stream and the polling fallback
               can only 401 without a credential, and the fallback would sit in a 1 Hz loop of
               rejected requests — filling the daemon's rate limiter with our own failures and
               writing an audit record for the window. Wait for the key; the submit handler calls
               begin() again. */
            settled = true;
            setConn('down', 'key required');
            promptForKey('This daemon requires an API key.');
            return;
          }
          decide(true);
        })
        .catch(function () { decide(false); });
  }


  /* ───── strategy comparison ─────────────────────────────────────────────
     Polled on its own timer rather than carried in the SSE frame. The frame goes out at 4 Hz to
     every client; the NAV rings behind this only advance once a second, and two curves of a few
     thousand points would dominate the stream for data that had not changed. Five seconds is
     already faster than the underlying rings move.

     Hidden entirely unless there are at least two instances, and left hidden while the daemon
     answers 409 — the "not enough overlap yet" case, which is normal for the first few seconds
     after a second strategy starts and is not worth showing as an error. */
  var CMP_STATS = [
    ['correlation',        function (r) { return C.fmtNum(r.correlation); }],
    ['beta',               function (r) { return C.fmtNum(r.beta); }],
    ['active return (ann)', function (r) { return pct(r.active_return_ann); }],
    ['tracking error (ann)', function (r) { return pct(r.tracking_error_ann); }],
    ['information ratio',  function (r) { return C.fmtNum(r.information_ratio); }],
    ['capture ratio',      function (r) { return C.fmtNum(r.capture_ratio); }]
  ];

  function pct(v) {
    return (v === null || v === undefined || !isFinite(v)) ? '—' : (v * 100).toFixed(2) + '%';
  }

  function hideCompare() {
    var p = document.getElementById('compare-panel');
    if (p) p.hidden = true;
  }

  function renderCompare(d) {
    var panel = document.getElementById('compare-panel');
    if (!panel) return;
    panel.hidden = false;

    text(document.getElementById('cmp-a-name'), d.a_id);
    text(document.getElementById('cmp-b-name'), d.b_id);
    text(document.getElementById('cmp-note'),
         d.n_periods + ' aligned points · ' + Math.round(Number(d.overlap_ns) / 1e9) + 's overlap');

    var svg = document.getElementById('cmp-chart');
    if (svg) {
      /* Timestamps are int64 and arrive as JSON numbers; Number() is exact enough here because the
         chart only needs relative position, and the domain is a few hours wide at most. */
      C.lines(svg, [
        { points: d.a.curve.map(function (p) { return [Number(p[0]), p[1]]; }), cls: 'ch-line cmp-a' },
        { points: d.b.curve.map(function (p) { return [Number(p[0]), p[1]]; }), cls: 'ch-line cmp-b' }
      ]);
    }

    var tbl = document.getElementById('cmp-stats');
    if (tbl) {
      tbl.textContent = '';
      CMP_STATS.forEach(function (row) {
        var tr = document.createElement('tr');
        var k = document.createElement('td');
        k.textContent = row[0];
        var v = document.createElement('td');
        v.textContent = row[1](d.b_vs_a);
        tr.appendChild(k);
        tr.appendChild(v);
        tbl.appendChild(tr);
      });
    }
  }

  function pollCompare() {
    api('/api/strategies')
      .then(function (r) { return r.ok ? r.json() : null; })
      .then(function (j) {
        var xs = (j && j.instances) || [];
        if (xs.length < 2) { hideCompare(); return null; }
        var a = encodeURIComponent(xs[0].strategy_id);
        var b = encodeURIComponent(xs[1].strategy_id);
        return api('/api/compare?a=' + a + '&b=' + b).then(function (r) {
          /* 409 is "not comparable yet", not a failure worth surfacing. */
          if (r.status === 409) { hideCompare(); return null; }
          return r.ok ? r.json() : null;
        });
      })
      .then(function (d) { if (d && !d.error) renderCompare(d); })
      .catch(function () { /* a transient failure just leaves the last render in place */ });
  }

  function wireKeyPrompt() {
    var form = document.getElementById('key-form');
    if (form) {
      form.addEventListener('submit', function (ev) {
        ev.preventDefault();
        var input = document.getElementById('key-input');
        if (!input || !input.value) return;
        setApiKey(input.value.trim());
        input.value = '';
        var el = document.getElementById('key-prompt');
        if (el) el.hidden = true;
        refreshWhoami();
        begin();
      });
    }
    var out = document.getElementById('sign-out');
    if (out) {
      out.addEventListener('click', function () {
        setApiKey('');
        applyScopes('read');   /* signed out: assume the least until a key says otherwise */
        promptForKey('Signed out.');
      });
    }
  }

  document.addEventListener('DOMContentLoaded', function () {
    wireKeyPrompt();
    refreshWhoami();
    render({ telemetry: { overall: { state: 'ok' }, latency: {}, bus: {}, components: [], alerts: [] },
             runtime: { instances: [], total_nav: 0, events: 0 } });
    begin();
    pollCompare();
    setInterval(pollCompare, 5000);
  });
})();
