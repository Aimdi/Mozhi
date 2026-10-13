/// Turns what the user typed or pasted into a fetchable http(s) [Uri].
///
/// * Surrounding whitespace is ignored; when the input contains spaces
///   (e.g. a pasted message), the first `http(s)://` link in it is used.
/// * `https://` is added when no scheme is given (`example.com/a` and
///   `//example.com/a` both become `https://example.com/a`).
/// * Only `http` and `https` are accepted, and the host must be
///   `localhost`, an IP address or a dotted domain name.
/// * The fragment (`#section`) is dropped: it is never sent to servers.
///
/// Returns null when no valid address can be made from [input].
Uri? normalizeWebUrl(String input) {
  var text = input.trim();
  if (text.isEmpty) return null;
  if (text.contains(_whitespace)) {
    final link = _embeddedLink.firstMatch(text);
    if (link == null) return null;
    text = link.group(0)!;
  }
  if (!_hasScheme.hasMatch(text)) {
    text = text.startsWith('//') ? 'https:$text' : 'https://$text';
  }
  final uri = Uri.tryParse(text);
  if (uri == null || !(uri.isScheme('http') || uri.isScheme('https'))) {
    return null;
  }
  final host = uri.host;
  if (host.isEmpty ||
      host.startsWith('.') ||
      host.contains('..') ||
      host.startsWith('-')) {
    return null;
  }
  final isIpv6 = host.contains(':');
  if (host != 'localhost' && !isIpv6 && !host.contains('.')) return null;
  if (!isIpv6 && !_hostCharacters.hasMatch(host)) return null;
  return uri.hasFragment ? uri.removeFragment() : uri;
}

/// Whether [text] is a single token that looks like a web address
/// (`https://…`, `www.…` or `domain.tld/…`), e.g. to offer "translate this
/// page" when a link is typed into the text translator.
bool isLikelyWebUrl(String text) {
  final trimmed = text.trim();
  if (trimmed.isEmpty || trimmed.contains(_whitespace)) return false;
  if (RegExp('^https?://', caseSensitive: false).hasMatch(trimmed)) {
    return normalizeWebUrl(trimmed) != null;
  }
  return _bareDomain.hasMatch(trimmed) && normalizeWebUrl(trimmed) != null;
}

final _whitespace = RegExp(r'\s');
final _hasScheme = RegExp(r'^[a-zA-Z][a-zA-Z0-9+.\-]*://');
final _embeddedLink = RegExp(r'https?://[^\s<>"]+', caseSensitive: false);

/// Letters (including IDN), digits, dots and hyphens.
final _hostCharacters = RegExp(r'^[\p{L}\p{N}.\-]+$', unicode: true);

/// `domain.tld` with an alphabetic TLD, optionally followed by a path.
final _bareDomain = RegExp(
  r'^(?:[\p{L}\p{N}\-]+\.)+\p{L}{2,}(?::\d+)?(?:[/?#]\S*)?$',
  unicode: true,
);
