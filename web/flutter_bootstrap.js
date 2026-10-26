{{flutter_js}}
{{flutter_build_config}}

// Mozhi: the engine initialisation (Flutter's default, plus the font
// setting below). A file, not inline, so the Content Security Policy can
// forbid inline scripts.
//
// CanvasKit draws text with Roboto, and with Noto fonts for what Roboto
// lacks (CJK, Indic and Arabic scripts, emoji, symbols), which it downloads
// when they are first needed. tool/web_fallback_fonts.py copies those fonts
// into the build (fallback_fonts/) and turns this on, so that they come
// from this server; without it (a plain `flutter build web`) they come
// from fonts.gstatic.com, which then sees the user's IP address and which
// scripts they read. See docs/building.md.
const mozhiSelfHostedFonts = false;

// No `serviceWorkerSettings`: Flutter's own service worker (deprecated; it
// only removes itself) would take the place of Mozhi's app shell
// (mozhi_sw.js, registered by the app: lib/platform/app_shell.dart), whose
// registration replaces an old one of Flutter's.
_flutter.loader.load({
  config: mozhiSelfHostedFonts
    ? { fontFallbackBaseUrl: new URL('fallback_fonts/', document.baseURI).href }
    : {},
});
