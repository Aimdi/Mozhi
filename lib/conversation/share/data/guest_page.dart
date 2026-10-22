import 'dart:convert';

import 'package:intl/intl.dart' show Bidi;
import 'package:mozhi/l10n/l10n.dart';

/// The guest page of a shared conversation: one small self-contained page
/// (this HTML, [guestPageCss] and [guestPageScript], served by the host's
/// phone; nothing from anywhere else, no cookies), which works in any
/// modern mobile browser.
///
/// Guests pick their language (and enter the PIN), then follow the
/// conversation in their language over Server-Sent Events, and may reply.
/// The texts of the page are the app's, in the guest's language when the
/// app has it ([guestPageStrings]); the page fills them in, so the HTML only
/// carries the configuration ([config], JSON) and the `<noscript>` text.
String renderGuestPage({
  required String base,
  required Map<String, Object?> config,
  required AppLocalizations l10n,
}) {
  final strings = guestPageStrings(l10n);
  final json = jsonEncode({...config, 'base': base, 'strings': strings})
      // Never `</script>` (or `<!--`) inside the script element.
      .replaceAll('<', r'\u003c');
  return _template
      .replaceAll('{{lang}}', _escape(strings['_locale']!))
      .replaceAll('{{dir}}', _escape(strings['_dir']!))
      .replaceAll('{{title}}', _escape(strings['title']!))
      .replaceAll('{{noscript}}', _escape(strings['noscript']!))
      .replaceAll('{{base}}', _escape(base))
      .replaceAll('{{config}}', json);
}

/// The page's texts in [l10n]'s language. Placeholders stay as
/// `{language}`, `{languages}` and `{number}` for the page to fill in;
/// `_locale` and `_dir` are the language and its direction.
Map<String, String> guestPageStrings(AppLocalizations l10n) => {
  '_locale': l10n.localeName,
  '_dir': Bidi.isRtlLanguage(l10n.localeName) ? 'rtl' : 'ltr',
  'title': l10n.conversationShareGuestTitle,
  'welcome': l10n.conversationShareGuestWelcome,
  'language': l10n.conversationShareGuestLanguage,
  'pin': l10n.conversationShareGuestPin,
  'pinHint': l10n.conversationShareGuestPinHint,
  'join': l10n.conversationShareGuestJoin,
  'wrongPin': l10n.conversationShareGuestWrongPin,
  'full': l10n.conversationShareGuestFull,
  'locked': l10n.conversationShareGuestLocked,
  'tooMany': l10n.conversationShareGuestTooMany,
  'languageLimit': l10n.conversationShareGuestLanguageLimit('{languages}'),
  'connecting': l10n.conversationShareGuestConnecting,
  'reconnecting': l10n.conversationShareGuestReconnecting,
  'unreachable': l10n.conversationShareGuestUnreachable,
  'ended': l10n.conversationShareGuestEnded,
  'endedBody': l10n.conversationShareGuestEndedBody,
  'conversation': l10n.conversationShareGuestConversation,
  'empty': l10n.conversationShareGuestEmpty,
  'replyLabel': l10n.conversationShareGuestReplyLabel,
  'send': l10n.conversationShareGuestSend,
  'tooFast': l10n.conversationShareGuestTooFast,
  'tooLong': l10n.conversationShareGuestTooLong,
  'repliesOff': l10n.conversationShareGuestRepliesOff,
  'translating': l10n.conversationShareGuestTranslating,
  'notTranslated': l10n.conversationShareGuestNotTranslated,
  'original': l10n.conversationShareGuestOriginal('{language}'),
  'host': l10n.conversationShareGuestHost,
  'partner': l10n.conversationShareGuestPartner,
  'guest': l10n.conversationShareGuestNumber('{number}'),
  'you': l10n.conversationShareGuestYou,
  'error': l10n.conversationShareGuestError,
  'noscript': l10n.conversationShareGuestNoScript,
  'footnote': l10n.conversationShareGuestFootnote,
};

String _escape(String text) => text
    .replaceAll('&', '&amp;')
    .replaceAll('<', '&lt;')
    .replaceAll('>', '&gt;')
    .replaceAll('"', '&quot;')
    .replaceAll("'", '&#39;');

const _template = '''
<!doctype html>
<html lang="{{lang}}" dir="{{dir}}">
<head>
<meta charset="utf-8">
<meta name="viewport" content="width=device-width, initial-scale=1, viewport-fit=cover">
<meta name="color-scheme" content="light dark">
<meta name="referrer" content="no-referrer">
<meta name="robots" content="noindex, nofollow">
<title>{{title}}</title>
<link rel="icon" href="data:,">
<link rel="stylesheet" href="{{base}}/app.css">
<script type="application/json" id="config">{{config}}</script>
<script src="{{base}}/app.js" defer></script>
</head>
<body>
<header class="bar">
<h1 data-s="title">{{title}}</h1>
<div class="tools" id="tools" hidden>
<label for="language-switch" class="sr-only" data-s="language"></label>
<select id="language-switch"></select>
</div>
</header>
<noscript><p class="status">{{noscript}}</p></noscript>
<p id="status" class="status" role="status" aria-live="polite"></p>
<main>
<section id="join" hidden>
<form id="join-form" novalidate>
<p class="lead" data-s="welcome"></p>
<label for="join-language" data-s="language"></label>
<select id="join-language"></select>
<div id="pin-field" hidden>
<label for="join-pin" data-s="pin"></label>
<input id="join-pin" inputmode="numeric" pattern="[0-9]*" maxlength="4" autocomplete="off" aria-describedby="pin-hint">
<p id="pin-hint" class="hint" data-s="pinHint"></p>
</div>
<p id="join-error" class="error" role="alert"></p>
<button type="submit" id="join-button" data-s="join"></button>
</form>
</section>
<section id="live" hidden>
<ol id="turns" class="turns" data-s-label="conversation"></ol>
<p id="empty" class="empty" data-s="empty"></p>
</section>
<section id="ended" hidden>
<h2 data-s="ended"></h2>
<p data-s="endedBody"></p>
</section>
</main>
<p id="replies-off" class="status" data-s="repliesOff" hidden></p>
<form id="reply-form" class="composer" hidden>
<label for="reply" class="sr-only" data-s="replyLabel"></label>
<textarea id="reply" rows="2" maxlength="500" enterkeyhint="send" data-s-placeholder="replyLabel"></textarea>
<button type="submit" id="send" data-s="send"></button>
</form>
<div id="announcer" class="sr-only" aria-live="polite"></div>
<p class="footnote" data-s="footnote"></p>
</body>
</html>
''';

/// The guest page's style: large readable text, the system font, light or
/// dark by the guest's system setting, 48 px touch targets.
const guestPageCss = '''
:root{color-scheme:light dark;--bg:#fbf8fd;--fg:#1b1b20;--muted:#5d5e67;--card:#efedf4;--mine:#dce1ff;--accent:#3d5ba9;--on-accent:#fff;--border:#c6c5d0;--error:#ba1a1a;font-size:112.5%}
@media (prefers-color-scheme:dark){:root{--bg:#121318;--fg:#e4e1e9;--muted:#aaa9b4;--card:#1f1f25;--mine:#2a3a6b;--accent:#b3c5ff;--on-accent:#0f2a5f;--border:#46464f;--error:#ffb4ab}}
*{box-sizing:border-box}
html,body{margin:0;background:var(--bg);color:var(--fg);font-family:system-ui,-apple-system,"Segoe UI",Roboto,"Noto Sans",sans-serif;line-height:1.45;-webkit-text-size-adjust:100%}
body{min-height:100vh;display:flex;flex-direction:column}
[hidden]{display:none!important}
.bar{position:sticky;top:0;z-index:1;display:flex;align-items:center;justify-content:space-between;gap:.75rem;padding:.6rem 1rem;padding-top:max(.6rem,env(safe-area-inset-top));background:var(--bg);border-bottom:1px solid var(--border)}
h1{font-size:1.1rem;margin:0}
h2{font-size:1.5rem}
select,input,textarea,button{font:inherit;color:inherit}
select,input,textarea{width:100%;min-height:48px;padding:.65rem .8rem;background:var(--card);border:1px solid var(--border);border-radius:.75rem}
.tools select{width:auto;max-width:55vw}
button{min-height:48px;min-width:48px;padding:.6rem 1.25rem;border:0;border-radius:999px;background:var(--accent);color:var(--on-accent);font-weight:600;cursor:pointer}
button:disabled{opacity:.6}
:focus-visible{outline:3px solid var(--accent);outline-offset:2px}
main{flex:1;width:100%;max-width:44rem;margin:0 auto;padding:1rem}
form label{display:block;margin:1rem 0 .4rem;font-weight:600}
#join-form button{margin-top:1rem;width:100%}
.lead{font-size:1.15rem;margin-top:0}
.hint{margin:.35rem 0 0;font-size:.9rem;color:var(--muted)}
.error{min-height:1.4em;color:var(--error)}
.status{margin:0;padding:.5rem 1rem;text-align:center;color:var(--muted)}
.status:empty{display:none}
.turns{list-style:none;margin:0;padding:0;display:flex;flex-direction:column;gap:.75rem}
.turn{align-self:flex-start;max-width:94%;padding:.75rem 1rem;background:var(--card);border-radius:1.1rem}
.turn.you{align-self:flex-end;background:var(--mine)}
.who{margin:0 0 .2rem;font-size:.85rem;color:var(--muted)}
.text{margin:0;font-size:1.4rem;white-space:pre-wrap;overflow-wrap:anywhere}
.text.pending{color:var(--muted)}
.note,.original{margin:.35rem 0 0;font-size:.95rem;color:var(--muted);white-space:pre-wrap;overflow-wrap:anywhere}
.empty{margin-top:2rem;text-align:center;color:var(--muted)}
#ended{margin-top:3rem;text-align:center}
.composer{position:sticky;bottom:0;display:flex;align-items:flex-end;gap:.5rem;width:100%;max-width:44rem;margin:0 auto;padding:.6rem 1rem;padding-bottom:max(.6rem,env(safe-area-inset-bottom));background:var(--bg);border-top:1px solid var(--border)}
.composer textarea{flex:1;resize:none}
.footnote{margin:0;padding:.5rem 1rem 1rem;font-size:.8rem;text-align:center;color:var(--muted)}
.sr-only{position:absolute;width:1px;height:1px;margin:-1px;padding:0;overflow:hidden;clip:rect(0,0,0,0);white-space:nowrap;border:0}
''';

/// The guest page's script (plain ES2017, no libraries). It only ever sets
/// `textContent`, so nothing a guest or the host types becomes markup.
const guestPageScript = r'''
(function () {
  'use strict';
  var config = JSON.parse(document.getElementById('config').textContent);
  var base = config.base;
  var strings = config.strings;
  var storageKey = 'mozhi-share:' + base;
  var session = null;
  var source = null;
  var ended = false;
  var repliesAllowed = true;
  var failingSince = 0;
  var seen = null;
  var shown = '';

  function $(id) { return document.getElementById(id); }

  function t(key, values) {
    var text = strings[key] || '';
    if (values) {
      Object.keys(values).forEach(function (name) {
        text = text.split('{' + name + '}').join(String(values[name]));
      });
    }
    return text;
  }

  function applyStrings() {
    document.documentElement.lang = strings._locale || 'en';
    document.documentElement.dir = strings._dir || 'ltr';
    document.title = t('title');
    var i, nodes = document.querySelectorAll('[data-s]');
    for (i = 0; i < nodes.length; i++) nodes[i].textContent = t(nodes[i].getAttribute('data-s'));
    nodes = document.querySelectorAll('[data-s-placeholder]');
    for (i = 0; i < nodes.length; i++) nodes[i].setAttribute('placeholder', t(nodes[i].getAttribute('data-s-placeholder')));
    nodes = document.querySelectorAll('[data-s-label]');
    for (i = 0; i < nodes.length; i++) nodes[i].setAttribute('aria-label', t(nodes[i].getAttribute('data-s-label')));
  }

  function setStrings(next) {
    if (next) { strings = next; applyStrings(); }
  }

  function load() {
    try { var raw = window.sessionStorage.getItem(storageKey); return raw ? JSON.parse(raw) : null; } catch (e) { return null; }
  }

  function save() {
    try {
      if (session) window.sessionStorage.setItem(storageKey, JSON.stringify(session));
      else window.sessionStorage.removeItem(storageKey);
    } catch (e) { /* Private mode: the page works without it. */ }
  }

  function setStatus(text) { $('status').textContent = text; }

  function show(section) {
    ['join', 'live', 'ended'].forEach(function (id) { $(id).hidden = id !== section; });
    $('tools').hidden = section !== 'live';
    $('reply-form').hidden = section !== 'live' || !repliesAllowed;
    $('replies-off').hidden = section !== 'live' || repliesAllowed;
  }

  function fillLanguages(select, selected) {
    select.textContent = '';
    config.languages.forEach(function (language) {
      var option = document.createElement('option');
      option.value = language.code;
      option.textContent = language.nativeName ? language.nativeName + ' (' + language.name + ')' : language.name;
      if (language.code === selected) option.selected = true;
      select.appendChild(option);
    });
  }

  function preferredLanguage() {
    var wanted = navigator.languages && navigator.languages.length ? navigator.languages : [navigator.language || 'en'];
    var codes = config.languages.map(function (language) { return language.code.toLowerCase(); });
    var i, j;
    for (i = 0; i < wanted.length; i++) {
      j = codes.indexOf(String(wanted[i]).toLowerCase());
      if (j >= 0) return config.languages[j].code;
    }
    for (i = 0; i < wanted.length; i++) {
      var primary = String(wanted[i]).toLowerCase().split('-')[0];
      for (j = 0; j < codes.length; j++) {
        if (codes[j].split('-')[0] === primary) return config.languages[j].code;
      }
    }
    return config.languages.length ? config.languages[0].code : '';
  }

  // No more languages can be added: which ones the guest may pick.
  function languageLimit(codes) {
    var names = (codes || []).map(function (code) {
      for (var i = 0; i < config.languages.length; i++) {
        var language = config.languages[i];
        if (language.code === code) return language.nativeName || language.name;
      }
      return code;
    });
    return t('languageLimit', { languages: names.join(', ') });
  }

  function limited(result) {
    return result.code === 409 && result.body && result.body.error === 'languageLimit';
  }

  function api(path, body) {
    var headers = { 'Content-Type': 'application/json' };
    if (session) { headers['X-Mozhi-Guest'] = session.guest; headers['X-Mozhi-Key'] = session.key; }
    return fetch(base + '/api/' + path, {
      method: 'POST', headers: headers, body: JSON.stringify(body || {}),
      cache: 'no-store', credentials: 'omit', referrerPolicy: 'no-referrer'
    }).then(function (response) {
      return response.json().catch(function () { return {}; }).then(function (data) {
        return { ok: response.ok, code: response.status, body: data };
      });
    });
  }

  function end() {
    ended = true;
    if (source) source.close();
    session = null;
    save();
    setStatus('');
    show('ended');
  }

  function rejoin() {
    if (source) source.close();
    session = null;
    save();
    setStatus('');
    show('join');
  }

  // The update stream was refused: the guest is unknown (removed after a
  // long absence) or the conversation is gone.
  function check() {
    fetch(base + '/api/hello', { cache: 'no-store', credentials: 'omit' }).then(function (response) {
      if (response.status === 200) rejoin(); else end();
    }, function () {
      setStatus(t('unreachable'));
      window.setTimeout(check, 5000);
    });
  }

  function connect() {
    if (source) source.close();
    fillLanguages($('language-switch'), session.language);
    show('live');
    setStatus(t('connecting'));
    source = new EventSource(base + '/api/events?guest=' + encodeURIComponent(session.guest) + '&key=' + encodeURIComponent(session.key));
    source.addEventListener('snapshot', function (event) {
      failingSince = 0;
      setStatus('');
      render(JSON.parse(event.data));
    });
    source.addEventListener('ended', end);
    source.onerror = function () {
      if (ended) return;
      if (source.readyState === 2) { check(); return; }
      if (!failingSince) failingSince = Date.now();
      setStatus(Date.now() - failingSince > 60000 ? t('unreachable') : t('reconnecting'));
    };
  }

  function speaker(turn) {
    var who = turn.who === 'host' ? t('host')
      : turn.who === 'you' ? t('you')
      : turn.who === 'guest' ? t('guest', { number: turn.guest })
      : t('partner');
    var time = '';
    try { time = new Date(turn.time).toLocaleTimeString([], { hour: '2-digit', minute: '2-digit' }); } catch (e) { time = ''; }
    return [who, turn.language, time].filter(Boolean).join(' · ');
  }

  function line(className) {
    var node = document.createElement('p');
    node.className = className;
    node.dir = 'auto';
    return node;
  }

  function set(node, text) {
    if (node.textContent !== text) node.textContent = text;
    node.hidden = !text;
  }

  function update(item, turn) {
    item.className = 'turn ' + turn.who;
    var pending = turn.state === 'translating';
    set(item.children[0], speaker(turn));
    set(item.children[1], pending && !turn.text ? t('translating') : turn.text);
    item.children[1].className = pending ? 'text pending' : 'text';
    set(item.children[2], turn.state === 'untranslated' ? t('notTranslated') : '');
    set(item.children[3], turn.state === 'translated' || (pending && turn.text) ? t('original', { language: turn.language }) + ' ' + turn.original : '');
  }

  function announce(turns) {
    var first = seen === null;
    if (first) seen = {};
    var message = '';
    turns.forEach(function (turn) {
      if (turn.state === 'translating' || seen[turn.id]) return;
      seen[turn.id] = true;
      if (!first && turn.who !== 'you') message = speaker(turn) + ': ' + turn.text;
    });
    if (message && message !== shown) {
      shown = message;
      $('announcer').textContent = message;
    }
  }

  function render(snapshot) {
    repliesAllowed = !!snapshot.repliesAllowed;
    show('live');
    var list = $('turns');
    var nearBottom = window.innerHeight + window.scrollY >= document.documentElement.scrollHeight - 120;
    var existing = {}, keep = {}, i;
    for (i = 0; i < list.children.length; i++) existing[list.children[i].getAttribute('data-id')] = list.children[i];
    snapshot.turns.forEach(function (turn, index) {
      var id = String(turn.id);
      var item = existing[id];
      if (!item) {
        item = document.createElement('li');
        item.setAttribute('data-id', id);
        item.appendChild(line('who'));
        item.appendChild(line('text'));
        item.appendChild(line('note'));
        item.appendChild(line('original'));
      }
      update(item, turn);
      keep[id] = true;
      if (list.children[index] !== item) list.insertBefore(item, list.children[index] || null);
    });
    Object.keys(existing).forEach(function (id) { if (!keep[id]) list.removeChild(existing[id]); });
    $('empty').hidden = snapshot.turns.length > 0;
    if (nearBottom) window.scrollTo(0, document.documentElement.scrollHeight);
    announce(snapshot.turns);
  }

  $('join-form').addEventListener('submit', function (event) {
    event.preventDefault();
    var button = $('join-button');
    button.disabled = true;
    $('join-error').textContent = '';
    api('join', { language: $('join-language').value, pin: $('join-pin').value }).then(function (result) {
      button.disabled = false;
      if (result.ok) {
        session = { guest: result.body.guest, key: result.body.key, language: result.body.language };
        save();
        setStrings(result.body.strings);
        connect();
        return;
      }
      if (limited(result)) { $('join-error').textContent = languageLimit(result.body.languages); return; }
      var reasons = { 403: 'wrongPin', 409: 'full', 423: 'locked', 429: 'tooMany', 410: 'ended' };
      $('join-error').textContent = t(reasons[result.code] || 'error');
      if (result.code === 410) end();
      if (result.code === 403) { $('join-pin').value = ''; $('join-pin').focus(); }
    }, function () {
      button.disabled = false;
      $('join-error').textContent = t('unreachable');
    });
  });

  $('language-switch').addEventListener('change', function () {
    var select = this;
    var code = select.value;
    api('language', { language: code }).then(function (result) {
      if (result.ok) {
        session.language = code;
        save();
        setStrings(result.body.strings);
      } else {
        select.value = session.language;
        setStatus(limited(result) ? languageLimit(result.body.languages) : t(result.code === 429 ? 'tooFast' : 'error'));
        if (result.code === 401) check();
      }
    }, function () { select.value = session.language; setStatus(t('unreachable')); });
  });

  $('reply-form').addEventListener('submit', function (event) {
    event.preventDefault();
    var box = $('reply');
    var text = box.value.trim();
    if (!text) return;
    var button = $('send');
    button.disabled = true;
    api('reply', { text: text }).then(function (result) {
      button.disabled = false;
      if (result.ok) { box.value = ''; setStatus(''); box.focus(); return; }
      var reasons = { 429: 'tooFast', 413: 'tooLong', 403: 'repliesOff', 410: 'ended' };
      setStatus(t(reasons[result.code] || 'error'));
      if (result.code === 401) check();
      if (result.code === 410) end();
    }, function () {
      button.disabled = false;
      setStatus(t('unreachable'));
    });
  });

  $('reply').addEventListener('keydown', function (event) {
    if (event.key === 'Enter' && !event.shiftKey && !event.isComposing && event.keyCode !== 229) {
      event.preventDefault();
      $('send').click();
    }
  });

  applyStrings();
  fillLanguages($('join-language'), preferredLanguage());
  $('pin-field').hidden = !config.pin;
  session = load();
  if (session && session.guest && session.key) connect(); else { session = null; show('join'); }
})();
''';
