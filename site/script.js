/* Mozhi site: theme toggle, example switcher and copy button.
   No tracking, no network requests. The page works without this file. */
(function () {
  'use strict';

  var root = document.documentElement;
  var KEY = 'mozhi-site-theme';

  // Runs in <head> so a saved theme applies before the first paint.
  try {
    var saved = localStorage.getItem(KEY);
    if (saved === 'light' || saved === 'dark') root.setAttribute('data-theme', saved);
  } catch (e) { /* storage unavailable: follow the system theme */ }

  var reduceMotion = window.matchMedia && window.matchMedia('(prefers-reduced-motion: reduce)').matches;

  // [source language, code, target language, code, source, translation, kind, engine]
  var EXAMPLES = [
    ['Tamil', 'ta', 'English', 'en', 'வணக்கம்! இன்று எப்படி இருக்கிறீர்கள்?', 'Hello! How are you today?', 'mozhi', 'Mozhi · Google'],
    ['English', 'en', 'German', 'de', 'Could you send me the report by Friday?', 'Könnten Sie mir den Bericht bis Freitag schicken?', 'ai', 'AI · Claude · Formal'],
    ['Spanish', 'es', 'English', 'en', '¿Dónde está la estación de tren más cercana?', 'Where is the nearest train station?', 'mozhi', 'Mozhi · DeepL'],
    ['English', 'en', 'Japanese', 'ja', 'Thanks so much for your help!', '助けてくれて本当にありがとう！', 'local', 'Local · Ollama · Informal']
  ];

  function byId(id) { return document.getElementById(id); }

  function initTheme() {
    var btn = byId('theme-toggle');
    if (!btn || !window.matchMedia) return;
    var mq = window.matchMedia('(prefers-color-scheme: dark)');
    function isDark() {
      var t = root.getAttribute('data-theme');
      return t ? t === 'dark' : mq.matches;
    }
    function sync() { btn.setAttribute('aria-pressed', isDark() ? 'true' : 'false'); }
    btn.addEventListener('click', function () {
      var next = isDark() ? 'light' : 'dark';
      var system = mq.matches ? 'dark' : 'light';
      try {
        if (next === system) localStorage.removeItem(KEY); else localStorage.setItem(KEY, next);
      } catch (e) { /* not persisted */ }
      if (next === system) root.removeAttribute('data-theme'); else root.setAttribute('data-theme', next);
      sync();
    });
    if (mq.addEventListener) mq.addEventListener('change', sync);
    sync();
    btn.hidden = false;
  }

  function initDemo() {
    var picker = byId('demo-picker');
    var demo = byId('demo');
    if (!picker || !demo) return;
    var from = byId('d-from'), to = byId('d-to'), src = byId('d-src');
    var out = byId('d-out'), engine = byId('d-engine');
    var buttons = picker.querySelectorAll('button');
    var timer;

    function show(i) {
      var ex = EXAMPLES[i];
      if (!ex) return;
      for (var b = 0; b < buttons.length; b++) {
        buttons[b].setAttribute('aria-pressed', b === i ? 'true' : 'false');
      }
      demo.classList.add('is-swapping');
      clearTimeout(timer);
      timer = setTimeout(function () {
        from.textContent = ex[0];
        src.lang = ex[1];
        to.textContent = ex[2];
        out.lang = ex[3];
        src.textContent = ex[4];
        out.textContent = ex[5];
        engine.setAttribute('data-kind', ex[6]);
        engine.textContent = ex[7];
        demo.classList.remove('is-swapping');
      }, reduceMotion ? 0 : 180);
    }

    picker.addEventListener('click', function (event) {
      var btn = event.target.closest && event.target.closest('button[data-i]');
      if (btn) show(Number(btn.getAttribute('data-i')));
    });
    picker.hidden = false;
  }

  function initCopy() {
    if (!navigator.clipboard || !window.isSecureContext) return;
    var buttons = document.querySelectorAll('button[data-copy]');
    Array.prototype.forEach.call(buttons, function (btn) {
      var source = byId(btn.getAttribute('data-copy'));
      var label = btn.querySelector('.copy-label');
      if (!source || !label) return;
      var reset;
      btn.addEventListener('click', function () {
        navigator.clipboard.writeText(source.textContent).then(function () {
          label.textContent = 'Copied';
        }, function () {
          label.textContent = 'Copy failed';
        });
        clearTimeout(reset);
        reset = setTimeout(function () { label.textContent = 'Copy'; }, 2000);
      });
      label.setAttribute('aria-live', 'polite');
      btn.hidden = false;
    });
  }

  function init() {
    initTheme();
    initDemo();
    initCopy();
  }

  if (document.readyState === 'loading') {
    document.addEventListener('DOMContentLoaded', init);
  } else {
    init();
  }
})();
