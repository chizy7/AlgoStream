/* ═══════════════════════════════════════════════════════════════════
   Minimal OCaml syntax highlighter.
   Deliberately small: one pass, one alternation, no library. Order in
   the alternation is the precedence — comments and strings are matched
   whole first, so identifiers inside them are never re-tokenised.
   ═══════════════════════════════════════════════════════════════════ */
(function () {
  'use strict';

  var KEYWORDS = [
    'let', 'in', 'and', 'rec', 'module', 'val', 'type', 'open', 'include',
    'fun', 'function', 'match', 'with', 'if', 'then', 'else', 'begin', 'end',
    'struct', 'sig', 'of', 'do', 'done', 'for', 'to', 'downto', 'while',
    'try', 'when', 'as', 'mutable', 'external', 'exception', 'assert',
    'lazy', 'new', 'object', 'method', 'class', 'true', 'false', 'ref',
    'not', 'mod', 'land', 'lor', 'lxor', 'lsl', 'lsr', 'asr'
  ];

  var RE = new RegExp(
    '(\\(\\*[\\s\\S]*?\\*\\))' +                 /* 1 · comment           */
    '|("(?:[^"\\\\]|\\\\.)*")' +                 /* 2 · string literal    */
    '|(~[a-zA-Z_][A-Za-z0-9_\']*)' +             /* 3 · labelled argument */
    '|\\b(' + KEYWORDS.join('|') + ')\\b' +      /* 4 · keyword           */
    '|\\b([A-Z][A-Za-z0-9_\']*)' +               /* 5 · module / ctor     */
    '|\\b(\\d[\\d_]*(?:\\.[\\d_]*)?)',           /* 6 · number            */
    'g'
  );

  function esc(s) {
    return s.replace(/&/g, '&amp;').replace(/</g, '&lt;').replace(/>/g, '&gt;');
  }

  function classOf(m) {
    if (m[1]) return 'tok-cmt';
    if (m[2]) return 'tok-str';
    if (m[3]) return 'tok-lbl';
    if (m[4]) return 'tok-kw';
    if (m[5]) return 'tok-mod';
    return 'tok-num';
  }

  function highlight(src) {
    var out = '', last = 0, m;
    RE.lastIndex = 0;
    while ((m = RE.exec(src)) !== null) {
      out += esc(src.slice(last, m.index));
      out += '<span class="' + classOf(m) + '">' + esc(m[0]) + '</span>';
      last = m.index + m[0].length;
    }
    return out + esc(src.slice(last));
  }

  /* innerHTML is safe here: every character of the source runs through
     esc() before it is concatenated, so the only unescaped markup in the
     result is the <span> wrappers generated above. The input is the
     element's own textContent, which comes from static page markup —
     never from a URL, query string or network response. */
  function run() {
    var nodes = document.querySelectorAll('code[data-lang="ocaml"]');
    for (var i = 0; i < nodes.length; i++) {
      nodes[i].innerHTML = highlight(nodes[i].textContent);
    }
  }

  if (document.readyState === 'loading') {
    document.addEventListener('DOMContentLoaded', run);
  } else {
    run();
  }
})();
