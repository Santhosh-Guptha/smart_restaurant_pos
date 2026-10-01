/* ═══════════════════════════════════════════════════════════════════════
   SmartBizz — FX layer (3D, motion, scroll)
   Loaded after site.js with `defer`. Every feature checks for what it
   needs and quietly does nothing if the browser lacks it, so the page is
   always usable. With reduced motion requested, only the non-moving
   parts (count-up final values, layer states) are applied.
   ═════════════════════════════════════════════════════════════════════ */
(function () {
  'use strict';
  var root = document.documentElement;
  var reduce = window.matchMedia && matchMedia('(prefers-reduced-motion: reduce)').matches;
  var fine = window.matchMedia && matchMedia('(hover: hover) and (pointer: fine)').matches;
  var hasIO = 'IntersectionObserver' in window;
  var raf = window.requestAnimationFrame || function (f) { return setTimeout(f, 16); };
  var $$ = function (s, r) { return Array.prototype.slice.call((r || document).querySelectorAll(s)); };

  if (!reduce && hasIO) root.classList.add('fx');

  /* ── headings: split into words for the 3D rise ───────────────────── */
  function splitWords(el) {
    var i = 0;
    (function walk(node) {
      Array.prototype.slice.call(node.childNodes).forEach(function (n) {
        if (n.nodeType === 3) {
          if (!n.nodeValue.trim()) return;
          var frag = document.createDocumentFragment();
          n.nodeValue.split(/(\s+)/).forEach(function (part) {
            if (!part) return;
            if (/^\s+$/.test(part)) { frag.appendChild(document.createTextNode(part)); return; }
            var s = document.createElement('span'); s.className = 'w'; s.style.setProperty('--wi', i++); s.textContent = part;
            frag.appendChild(s);
          });
          n.parentNode.replaceChild(frag, n);
        } else if (n.nodeType === 1 && n.tagName !== 'BR') {
          // Gradient text is clipped to its own box, so keep it whole.
          if (n.classList.contains('grad') || n.classList.contains('soon')) { n.classList.add('w'); n.style.setProperty('--wi', i++); }
          else walk(n);
        }
      });
    })(el);
  }
  if (root.classList.contains('fx')) {
    $$('main h1, main h2').forEach(function (h) {
      splitWords(h); h.classList.add('fx-words');
      h.classList.remove('rv'); // the words carry the motion now
    });
  }

  /* ── one observer for everything that animates in ─────────────────── */
  if (hasIO) {
    var io = new IntersectionObserver(function (es) {
      es.forEach(function (e) {
        if (!e.isIntersecting) return;
        var t = e.target;
        t.classList.add('fx-in'); t.classList.add('in');
        if (t.hasAttribute('data-count')) countUp(t);
        io.unobserve(t);
      });
    }, { threshold: 0.2, rootMargin: '0px 0px -5% 0px' });
    $$('.fx-words, .flow, .matrix, [data-count], .flow li').forEach(function (el) { io.observe(el); });
    $$('.matrix tbody tr').forEach(function (tr, i) { tr.style.setProperty('--ri', i); });

    // Pause looping animations that are off-screen.
    var pause = new IntersectionObserver(function (es) {
      es.forEach(function (e) { e.target.classList.toggle('fx-off', !e.isIntersecting); });
    }, { threshold: 0 });
    $$('.dv, .final, .ribbon, .lamp-glow').forEach(function (el) { pause.observe(el); });
  }

  /* ── numbers count up ─────────────────────────────────────────────── */
  function countUp(el) {
    var to = parseInt(el.getAttribute('data-count'), 10), suf = el.getAttribute('data-suffix') || '';
    if (reduce || !to) { el.textContent = to + suf; return; }
    var t0 = null, dur = 1200;
    function step(t) {
      if (!t0) t0 = t;
      var k = Math.min(1, (t - t0) / dur), e = 1 - Math.pow(1 - k, 3);
      el.textContent = Math.round(to * e) + suf;
      if (k < 1) raf(step);
    }
    el.textContent = '0' + suf; raf(step);
  }

  /* ── scroll: progress bar + exploded layers ───────────────────────── */
  var bar = document.querySelector('.fx-progress');
  var layers = document.getElementById('layers');
  var planes = layers ? $$('.ly', layers) : [], keys = layers ? $$('.ly-key li', layers) : [];
  var ticking = false;
  function onScroll() {
    ticking = false;
    var h = root.scrollHeight - innerHeight;
    if (bar) bar.style.setProperty('--sp', h > 0 ? (scrollY / h).toFixed(4) : 0);
    if (layers && !reduce) {
      var r = layers.getBoundingClientRect(), span = r.height - innerHeight;
      var p = span > 0 ? Math.min(1, Math.max(0, -r.top / span)) : 0.7;
      layers.style.setProperty('--p', p.toFixed(3));
      setActive(Math.min(planes.length - 1, Math.floor(p * planes.length * 0.999)));
    }
  }
  function setActive(n) {
    planes.forEach(function (el, i) { el.classList.toggle('on', i === n); });
    keys.forEach(function (el, i) { el.classList.toggle('on', i === n); });
  }
  if (layers && reduce) setActive(0);
  function req() { if (!ticking) { ticking = true; raf(onScroll); } }
  window.addEventListener('scroll', req, { passive: true });
  window.addEventListener('resize', req);
  onScroll();

  if (reduce) return; // everything below only moves things

  /* ── device stage: pointer tilt, gyro on phones, 3D screen flip ────── */
  var stage = document.querySelector('.dv-stage');
  if (stage) {
    var setTilt = function (x, y) { // x,y in -1..1
      stage.style.setProperty('--ry', (x * 14).toFixed(2) + 'deg');
      stage.style.setProperty('--rx', (-y * 10).toFixed(2) + 'deg');
      stage.style.setProperty('--gx', (50 + x * 50).toFixed(1) + '%');
      stage.style.setProperty('--gy', (40 + y * 50).toFixed(1) + '%');
    };
    if (fine) {
      var hero = stage.closest('.hero') || stage;
      hero.addEventListener('pointermove', function (e) {
        var r = stage.getBoundingClientRect();
        var x = Math.max(-1, Math.min(1, ((e.clientX - r.left) / r.width - 0.5) * 2));
        var y = Math.max(-1, Math.min(1, ((e.clientY - r.top) / r.height - 0.5) * 2));
        stage.classList.add('tracking'); setTilt(x, y);
        hero.style.setProperty('--mx', (x * 40).toFixed(0) + 'px');
        hero.style.setProperty('--my', (y * 30).toFixed(0) + 'px');
      });
      hero.addEventListener('pointerleave', function () { stage.classList.remove('tracking'); setTilt(0, 0); });
    } else if ('DeviceOrientationEvent' in window) {
      var gyro = function (e) {
        if (e.gamma == null) return;
        stage.classList.add('tracking');
        setTilt(Math.max(-1, Math.min(1, e.gamma / 30)), Math.max(-1, Math.min(1, (e.beta - 45) / 30)));
      };
      var need = typeof DeviceOrientationEvent.requestPermission === 'function';
      if (need) { // iOS asks once, on a tap
        stage.addEventListener('click', function ask() {
          stage.removeEventListener('click', ask);
          DeviceOrientationEvent.requestPermission().then(function (s) { if (s === 'granted') addEventListener('deviceorientation', gyro, { passive: true }); }).catch(function () {});
        });
      } else addEventListener('deviceorientation', gyro, { passive: true });
    }

    // The screen flips on its vertical axis when the trade changes.
    // site.js adds .swap and removes it when it has painted the new screen;
    // this starts the new screen from the far side so it turns into view.
    if ('MutationObserver' in window) {
      var was = stage.classList.contains('swap');
      new MutationObserver(function () {
        var now = stage.classList.contains('swap');
        if (was && !now) {
          stage.classList.add('swap-in');
          void stage.offsetWidth;
          stage.classList.remove('swap-in');
        }
        was = now;
      }).observe(stage, { attributes: true, attributeFilter: ['class'] });
    }
  }

  /* ── cards: tilt + glare that follows the pointer ─────────────────── */
  if (fine) {
    $$('.md, .cat, .plan, .demo, .flow li, .stats > div, .ly-key li').forEach(function (el) {
      if (el.closest('.ly-key')) return;
      el.classList.add('fx-tilt');
      el.addEventListener('pointermove', function (e) {
        var r = el.getBoundingClientRect();
        var x = (e.clientX - r.left) / r.width, y = (e.clientY - r.top) / r.height;
        el.classList.add('tilting');
        el.style.setProperty('--ry', ((x - 0.5) * 12).toFixed(2) + 'deg');
        el.style.setProperty('--rx', ((0.5 - y) * 12).toFixed(2) + 'deg');
        el.style.setProperty('--gx', (x * 100).toFixed(1) + '%');
        el.style.setProperty('--gy', (y * 100).toFixed(1) + '%');
      });
      el.addEventListener('pointerleave', function () {
        el.classList.remove('tilting');
        el.style.setProperty('--rx', '0deg'); el.style.setProperty('--ry', '0deg');
      });
    });
  }

  /* ── module explorer: cards glide to their new places (FLIP) ──────── */
  var mods = document.getElementById('mods');
  if (mods && Element.prototype.animate) {
    var before = null;
    document.addEventListener('click', function (e) {
      if (!e.target.closest('.chip')) return;
      before = new Map();
      $$('.md', mods).forEach(function (m) { if (!m.hidden) before.set(m, m.getBoundingClientRect()); });
      setTimeout(function () { // after site.js has applied the filter
        var i = 0;
        $$('.md', mods).forEach(function (m) {
          if (m.hidden) return;
          var now = m.getBoundingClientRect(), was = before.get(m);
          if (was) {
            var dx = was.left - now.left, dy = was.top - now.top;
            if (dx || dy) m.animate([{ transform: 'translate(' + dx + 'px,' + dy + 'px)' }, { transform: 'none' }],
              { duration: 520, easing: 'cubic-bezier(.2,.8,.2,1)' });
          } else {
            m.animate([{ opacity: 0, transform: 'perspective(700px) rotateX(-70deg) translateY(30px) scale(.9)' },
                       { opacity: 1, transform: 'none' }],
              { duration: 620, delay: (i++) * 35, easing: 'cubic-bezier(.2,.8,.2,1)', fill: 'backwards' });
          }
        });
      }, 0);
    }, true);
  }
})();
