// Hides the loading splash (index.html) once Flutter draws its first frame.
// A separate file rather than an inline script so the Content Security
// Policy can forbid inline scripts.
window.addEventListener('flutter-first-frame', function () {
  var splash = document.getElementById('splash');
  if (!splash) return;
  splash.classList.add('done');
  setTimeout(function () { splash.remove(); }, 250);
}, { once: true });
