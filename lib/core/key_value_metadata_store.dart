import 'dart:convert';

import 'package:mozhi/core/key_value_store.dart';
import 'package:mozhi/core/network/url_credentials.dart';
import 'package:translation_repository/translation_repository.dart';

/// Persists the translation repository's metadata (Mozhi engine and
/// language lists) in a [KeyValueStore], usually the app's
/// [PreferencesStore].
///
/// Keys and values name the instance URL (`PersistedMetadata.keyFor`). A
/// URL with a user name and password (`https://user:password@host`) is
/// stored without them, since the store is not encrypted: [write] removes
/// them from the key and the value (and deletes an entry an older version
/// stored with them), and [read] puts them back into the value.
class KeyValueMetadataStore implements MetadataStore {
  new(this._store);

  final KeyValueStore _store;

  @override
  Future<String?> read(String key) async {
    final url = _urlOf(key);
    if (url == null) return await _store.read(key);
    final raw = await _store.read(_redactedKey(key, url));
    return raw == null
        ? null
        : _withUrl(raw, from: urlWithoutCredentials(url), to: url);
  }

  @override
  Future<void> write(String key, String value) async {
    final url = _urlOf(key);
    if (url == null) return await _store.write(key, value);
    await _store.write(
      _redactedKey(key, url),
      _withUrl(value, from: url, to: urlWithoutCredentials(url)),
    );
    await _store.delete(key);
  }

  /// The instance URL in [key] when it has credentials, else null.
  static String? _urlOf(String key) {
    final first = key.indexOf('|');
    final last = key.lastIndexOf('|');
    if (first < 0 || last <= first) return null;
    final url = key.substring(first + 1, last);
    return urlCredentials(url) == null ? null : url;
  }

  static String _redactedKey(String key, String url) =>
      key.replaceFirst('|$url|', '|${urlWithoutCredentials(url)}|');

  /// [raw] with its `url` field [from] replaced by [to] (unchanged when
  /// it is no such JSON object).
  static String _withUrl(
    String raw, {
    required String from,
    required String to,
  }) {
    try {
      final json = jsonDecode(raw);
      if (json is Map<String, dynamic> && json['url'] == from) {
        return jsonEncode({...json, 'url': to});
      }
    } on FormatException {
      // Not ours to fix.
    }
    return raw;
  }
}
