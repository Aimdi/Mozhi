/// Whether this build runs in a browser.
///
/// Pure Dart (no Flutter import), so cubits can use it and stay decoupled
/// from Flutter; same value as `kIsWeb`.
const bool runsInBrowser = bool.fromEnvironment('dart.library.js_interop');
