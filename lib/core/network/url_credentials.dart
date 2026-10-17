/// User names and passwords inside service URLs
/// (`https://user:password@host`), which are kept out of the plain
/// settings JSON (see `SettingsRepository`).
///
/// These work on the URL text, so a URL without credentials comes back
/// exactly as it was (no normalisation).
library;

/// The user-info of [url] (`user:password`, percent-encoded as written),
/// or null when it has none.
String? urlCredentials(String url) {
  final at = _userInfoEnd(url);
  if (at == null) return null;
  final start = url.indexOf('://') + 3;
  return at == start ? null : url.substring(start, at);
}

/// [url] without its user-info (unchanged when it has none).
String urlWithoutCredentials(String url) {
  final at = _userInfoEnd(url);
  if (at == null) return url;
  final start = url.indexOf('://') + 3;
  return '${url.substring(0, start)}${url.substring(at + 1)}';
}

/// [url] (without user-info) with [credentials] as its user-info. Empty
/// [credentials] leave [url] as it is.
String urlWithCredentials(String url, String credentials) {
  final plain = urlWithoutCredentials(url);
  final scheme = plain.indexOf('://');
  if (credentials.isEmpty || scheme < 0) return plain;
  final start = scheme + 3;
  return '${plain.substring(0, start)}$credentials@${plain.substring(start)}';
}

/// Index of the `@` that ends the user-info of [url], or null.
int? _userInfoEnd(String url) {
  final scheme = url.indexOf('://');
  if (scheme <= 0) return null;
  final start = scheme + 3;
  var end = url.length;
  for (final delimiter in const ['/', '?', '#']) {
    final index = url.indexOf(delimiter, start);
    if (index >= 0 && index < end) end = index;
  }
  final at = url.lastIndexOf('@', end - 1);
  return at < start ? null : at;
}
