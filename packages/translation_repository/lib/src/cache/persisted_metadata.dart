import 'dart:convert';

import 'package:meta/meta.dart';
import 'package:translation_repository/src/cache/metadata_store.dart';

/// A metadata value read back from a [MetadataStore].
@immutable
class StoredMetadata {
  const new({
    required this.url,
    required this.data,
    required this.encodedData,
    required this.savedAt,
  });

  /// The instance URL the value came from.
  final String url;

  /// The decoded JSON value.
  final Object? data;

  /// [data] as JSON (to compare with a fresh value).
  final String encodedData;

  /// When the value was stored.
  final DateTime savedAt;
}

/// Reads and writes timestamped JSON metadata (engine and language lists)
/// in a [MetadataStore], keyed by instance URL and list name.
///
/// Entries older than [maxAge] are never returned, and anything that does
/// not decode to the expected envelope (corrupt JSON, another format
/// version, another URL or name) is ignored. Store failures are swallowed:
/// the data is only a cache.
class PersistedMetadata {
  new(this._store, {required this.maxAge, required this._clock});

  /// Prefix of every key (the store may be shared with other data).
  static const keyPrefix = 'translation_repository.metadata.v1';

  /// Format version of the stored envelope.
  static const version = 1;

  final MetadataStore _store;
  final DateTime Function() _clock;

  /// How long a stored value may be served.
  final Duration maxAge;

  /// The store key of list [name] of the instance at [url].
  static String keyFor(String url, String name) => '$keyPrefix|$url|$name';

  /// The stored, unexpired value of [name] for [url], or null.
  Future<StoredMetadata?> read(String url, String name) async {
    final String? raw;
    try {
      raw = await _store.read(keyFor(url, name));
    } on Object {
      return null;
    }
    if (raw == null) return null;
    final Object? decoded;
    try {
      decoded = jsonDecode(raw);
    } on FormatException {
      return null;
    }
    if (decoded
        case {
          'v': version,
          'url': final String storedUrl,
          'name': final String storedName,
          'savedAt': final int savedAtMs,
          'data': final Object? data,
        }
        when storedUrl == url && storedName == name) {
      final savedAt = DateTime.fromMillisecondsSinceEpoch(savedAtMs);
      if (_clock().difference(savedAt) >= maxAge) return null;
      return StoredMetadata(
        url: url,
        data: data,
        encodedData: jsonEncode(data),
        savedAt: savedAt,
      );
    }
    return null;
  }

  /// Stores [data] (JSON-encodable) as list [name] of [url], timestamped
  /// now.
  Future<void> write(String url, String name, Object? data) async {
    try {
      await _store.write(
        keyFor(url, name),
        jsonEncode({
          'v': version,
          'url': url,
          'name': name,
          'savedAt': _clock().millisecondsSinceEpoch,
          'data': data,
        }),
      );
    } on Object {
      // Only a cache: the next successful load writes again.
    }
  }
}
