/* ═══════════════════════════════════════════════════════════════════
   Documentation page navigation — TOC scroll-spy.

   Highlights the last section whose top has passed the probe line.
   Computed directly rather than with IntersectionObserver: an observer
   band narrower than a section leaves scroll positions where nothing
   intersects, and the highlight then sticks on a stale entry.
   ═══════════════════════════════════════════════════════════════════ */
(function () {
  'use strict';

  var items = Array.prototype.slice.call(document.querySelectorAll('.toc a'))
    .map(function (a) { return { a: a, s: document.querySelector(a.getAttribute('href')) }; })
    .filter(function (it) { return it.s; });
  if (!items.length) return;

  var PROBE = 140;   /* px below the viewport top */
  var queued = false;

  function paint() {
    queued = false;
    var idx = 0;
    for (var i = 0; i < items.length; i++) {
      if (items[i].s.getBoundingClientRect().top <= PROBE) idx = i;
    }
    /* At the very bottom the last section may never cross the probe. */
    var doc = document.documentElement;
    if (window.innerHeight + window.scrollY >= doc.scrollHeight - 4) idx = items.length - 1;

    for (var j = 0; j < items.length; j++) {
      items[j].a.classList.toggle('active', j === idx);
    }
  }

  function schedule() {
    if (queued) return;
    queued = true;
    window.requestAnimationFrame(paint);
  }

  window.addEventListener('scroll', schedule, { passive: true });
  window.addEventListener('resize', schedule, { passive: true });
  paint();
})();
