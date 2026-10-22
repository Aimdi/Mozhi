import 'dart:convert';

import 'package:meta/meta.dart';
import 'package:translation_repository/src/dictionary_packs/offline_dictionary.dart';

/// One downloadable dictionary pack of a [DictionaryPackCatalog]
/// (`dictionary_catalog.json`, written by `tool/dictionary_packs.py
/// catalog`).
@immutable
final class DictionaryPackInfo {
  const new({
    required this.id,
    required this.language,
    required this.name,
    required this.url,
    required this.size,
    required this.sha256,
    this.glossLanguage = 'en',
    this.entries = 0,
    this.snapshot = '',
    this.license = 'CC BY-SA 4.0',
    this.source = 'Wiktionary',
  });

  factory fromJson(Map<String, Object?> json) {
    final id = _string(json, 'id');
    if (!_id.hasMatch(id)) throw FormatException('Invalid pack id', id);
    final file = _string(json, 'file');
    final url = Uri.tryParse(_string(json, 'url'));
    if (url == null || !url.isScheme('https') || url.host.isEmpty) {
      throw FormatException('Pack URLs must be https', json['url']);
    }
    if (url.pathSegments.lastOrNull != file || !file.endsWith(fileExtension)) {
      throw FormatException('The URL must name $file', '$url');
    }
    final sha256 = _string(json, 'sha256');
    if (!_hexSha256.hasMatch(sha256)) {
      throw FormatException(
        '"sha256" must be a lower-case hex SHA-256',
        sha256,
      );
    }
    final size = json['size'];
    if (size is! int || size <= 0) {
      throw FormatException('"size" must be a positive integer', size);
    }
    final entries = json['entries'] ?? 0;
    if (entries is! int || entries < 0) {
      throw FormatException('"entries" must be a count', entries);
    }
    return DictionaryPackInfo(
      id: id,
      language: _string(json, 'language'),
      glossLanguage: _string(json, 'glossLanguage', fallback: 'en'),
      name: _string(json, 'name'),
      url: url,
      size: size,
      sha256: sha256,
      entries: entries,
      snapshot: _string(json, 'snapshot', fallback: ''),
      license: _string(json, 'license', fallback: 'CC BY-SA 4.0'),
      source: _string(json, 'source', fallback: 'Wiktionary'),
    );
  }

  /// The extension of pack files.
  static const fileExtension = '.mzd';

  /// Unique in the catalogue, also the installed file's name: the language
  /// code, with the gloss language when it is not English (`de-de`).
  final String id;

  /// Language of the words.
  final String language;

  /// Language of the definitions.
  final String glossLanguage;

  /// English name of [language].
  final String name;
  final Uri url;

  /// Bytes of the file.
  final int size;

  /// Lower-case hex SHA-256 of the file.
  final String sha256;

  /// Entries in the pack.
  final int entries;
  final String snapshot;
  final String license;
  final String source;

  /// The file name: `<id>.mzd`.
  String get fileName => '$id$fileExtension';

  /// Whether this pack has the words of the app language [code].
  bool hasLanguage(String code) => dictionaryLanguageMatches(language, code);

  Map<String, Object?> toJson() => {
    'id': id,
    'language': language,
    'glossLanguage': glossLanguage,
    'name': name,
    'file': fileName,
    'url': url.toString(),
    'size': size,
    'sha256': sha256,
    'entries': entries,
    'snapshot': snapshot,
    'license': license,
    'source': source,
  };

  @override
  bool operator ==(Object other) =>
      other is DictionaryPackInfo &&
      other.id == id &&
      other.url == url &&
      other.size == size &&
      other.sha256 == sha256;

  @override
  int get hashCode => Object.hash(id, url, size, sha256);

  @override
  String toString() => 'DictionaryPackInfo($id)';
}

/// The dictionary packs the app can download: published as a GitHub
/// release by `.github/workflows/dictionary_packs.yaml`, their sizes and
/// SHA-256 pinned in the app. Empty until the first release.
@immutable
final class DictionaryPackCatalog {
  new(Iterable<DictionaryPackInfo> packs, {this.release, this.source})
    : packs = List.unmodifiable(packs);

  factory fromJson(Map<String, Object?> json) {
    final schema = json['schemaVersion'];
    if (schema != supportedSchemaVersion) {
      throw FormatException('Unsupported catalog schema', schema);
    }
    final packs = json['packs'];
    if (packs is! List<Object?>) throw const FormatException('Missing packs');
    final parsed = [
      for (final pack in packs)
        if (pack is Map<String, Object?>)
          DictionaryPackInfo.fromJson(pack)
        else
          throw FormatException('Invalid pack', pack),
    ];
    if (parsed.map((pack) => pack.id).toSet().length != parsed.length) {
      throw const FormatException('Duplicate pack ids');
    }
    return DictionaryPackCatalog(
      parsed..sort((a, b) => a.name.compareTo(b.name)),
      release: json['release'] as String?,
      source: json['source'] as String?,
    );
  }

  /// Parses `dictionary_catalog.json`. Throws [FormatException] when it is
  /// invalid.
  factory parse(String source) {
    final json = jsonDecode(source);
    if (json is! Map<String, Object?>) {
      throw const FormatException('The catalog must be a JSON object');
    }
    return DictionaryPackCatalog.fromJson(json);
  }

  static const supportedSchemaVersion = 1;

  /// Every pack, sorted by name.
  final List<DictionaryPackInfo> packs;

  /// The release the packs belong to, e.g. `dictionary-packs-2026-10-22`.
  final String? release;

  /// The release's page.
  final String? source;

  bool get isEmpty => packs.isEmpty;

  /// The pack with [id], if any.
  DictionaryPackInfo? byId(String id) {
    for (final pack in packs) {
      if (pack.id == id) return pack;
    }
    return null;
  }

  /// The packs with the words of the app language [code].
  List<DictionaryPackInfo> forLanguage(String code) => [
    for (final pack in packs)
      if (pack.hasLanguage(code)) pack,
  ];

  Map<String, Object?> toJson() => {
    'schemaVersion': supportedSchemaVersion,
    'release': ?release,
    'source': ?source,
    'packs': [for (final pack in packs) pack.toJson()],
  };
}

final _id = RegExp(r'^[a-z]{2,3}(-[a-z0-9]{2,8})*$');
final _hexSha256 = RegExp(r'^[0-9a-f]{64}$');

String _string(Map<String, Object?> json, String key, {String? fallback}) {
  final value = json[key];
  if (value is String && (value.isNotEmpty || fallback != null)) return value;
  if (value == null && fallback != null) return fallback;
  throw FormatException('Missing "$key"', json);
}

/// The folder of a model mirror that holds the dictionary packs (see
/// [dictionaryPackDownloadUrls]).
const dictionaryPackMirrorFolder = 'dictionary';

/// The URLs to download [pack] from, in the order to try them: without a
/// [mirror] (a base URL such as `https://example.org/models/`), the
/// catalogue's [DictionaryPackInfo.url] (the GitHub release); with one,
/// `<mirror>/dictionary/<id>.mzd`, then the catalogue URL when
/// [fallbackToDefault]. The mirror is not trusted: whichever URL answers,
/// the file must match the catalogue's size and SHA-256.
///
/// Throws [ArgumentError] when [mirror] is not an absolute `http` or
/// `https` URL without query and fragment.
List<Uri> dictionaryPackDownloadUrls(
  DictionaryPackInfo pack, {
  Uri? mirror,
  bool fallbackToDefault = false,
}) {
  if (mirror == null) return [pack.url];
  if (!(mirror.isScheme('https') || mirror.isScheme('http')) ||
      mirror.host.isEmpty ||
      mirror.hasQuery ||
      mirror.hasFragment) {
    throw ArgumentError.value(mirror, 'mirror', 'Not an http(s) base URL');
  }
  return [
    mirror.replace(
      pathSegments: [
        for (final segment in mirror.pathSegments)
          if (segment.isNotEmpty) segment,
        dictionaryPackMirrorFolder,
        pack.fileName,
      ],
    ),
    if (fallbackToDefault) pack.url,
  ];
}
