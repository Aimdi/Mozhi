import 'dart:js_interop';

@JS('document.baseURI')
external String? get _baseUri;

/// The URL the web app's files are relative to: `document.baseURI`, which
/// follows `<base href>` (so `models/` is next to the app, whatever its
/// sub-path or route), or null when the browser has none.
Uri? webAppBaseUrl() {
  // coverage:ignore-start
  final base = _baseUri;
  return base == null ? null : Uri.tryParse(base);
  // coverage:ignore-end
}
