import 'dart:convert';

import 'package:equatable/equatable.dart';
import 'package:mozhi/phrasebook/models/phrase.dart';

/// A starter phrasebook the app can download: one entry of the bundled
/// catalogue (`phrasebook_catalog.json` of a `phrasebooks-<date>` release,
/// written by `tool/phrasebooks.py catalog`), with the size and SHA-256
/// every download is checked against.
class StarterPhrasebookInfo extends Equatable {
  const new({
    required this.id,
    required this.language,
    required this.name,
    required this.url,
    required this.size,
    required this.sha256,
    this.baseLanguage = 'en',
    this.phrases = 0,
    this.revision = 0,
    this.sourceUrl = '',
    this.license = 'CC BY-SA 4.0',
  });

  /// Parses a catalogue entry. Throws [FormatException] when it is invalid:
  /// the id is not a language-code-like id, the URL is not `https` or does
  /// not end in `<id>.json.gz`, the size is not positive or the SHA-256 is
  /// not lower-case hex.
  factory fromJson(Map<String, Object?> json) {
    final id = json['id'];
    if (id is! String || !_id.hasMatch(id)) {
      throw FormatException('Invalid phrasebook id', id);
    }
    final url = Uri.tryParse(_string(json, 'url'));
    if (url == null || !url.isScheme('https') || url.host.isEmpty) {
      throw FormatException('Phrasebook URLs must be https', json['url']);
    }
    if (url.pathSegments.lastOrNull != '$id$fileExtension') {
      throw FormatException('The URL must name $id$fileExtension', '$url');
    }
    final sha256 = _string(json, 'sha256');
    if (!_hexSha256.hasMatch(sha256)) {
      throw FormatException('Invalid SHA-256', sha256);
    }
    final size = json['size'];
    if (size is! int || size <= 0 || size > maxSize) {
      throw FormatException('Invalid size', size);
    }
    final phrases = json['phrases'] ?? 0;
    final revision = json['revision'] ?? 0;
    if (phrases is! int || phrases < 0 || revision is! int || revision < 0) {
      throw FormatException('Invalid counts', json);
    }
    return StarterPhrasebookInfo(
      id: id,
      language: _string(json, 'language'),
      baseLanguage: _string(json, 'baseLanguage', fallback: 'en'),
      name: _string(json, 'name'),
      url: url,
      size: size,
      sha256: sha256,
      phrases: phrases,
      revision: revision,
      sourceUrl: _string(json, 'sourceUrl', fallback: ''),
      license: _string(json, 'license', fallback: 'CC BY-SA 4.0'),
    );
  }

  /// The extension of pack files (gzip'd JSON).
  static const fileExtension = '.json.gz';

  /// The largest pack the app accepts (bytes of the gzip'd file).
  static const int maxSize = 4 * 1024 * 1024;

  /// Unique in the catalogue: the language code of the phrases'
  /// translations, with the base language when it is not English
  /// (`pt`, `ja-de`).
  final String id;

  /// The language the phrases are translated into (the traveller's
  /// destination).
  final String language;

  /// The language of the phrases themselves (English for the English
  /// Wikivoyage).
  final String baseLanguage;

  /// English name of [language].
  final String name;
  final Uri url;

  /// Bytes of the file.
  final int size;

  /// Lower-case hex SHA-256 of the file.
  final String sha256;

  /// How many phrases it has.
  final int phrases;

  /// The Wikivoyage revision it was made from.
  final int revision;

  /// The Wikivoyage page.
  final String sourceUrl;
  final String license;

  /// The file name: `<id>.json.gz`.
  String get fileName => '$id$fileExtension';

  Map<String, Object?> toJson() => {
    'id': id,
    'language': language,
    'baseLanguage': baseLanguage,
    'name': name,
    'file': fileName,
    'url': url.toString(),
    'size': size,
    'sha256': sha256,
    'phrases': phrases,
    'revision': revision,
    'sourceUrl': sourceUrl,
    'license': license,
  };

  @override
  List<Object?> get props => [id, url, size, sha256];
}

/// The starter phrasebooks the app can download: published as a GitHub
/// release by `.github/workflows/phrasebooks.yaml`, their sizes and SHA-256
/// pinned in the app. Empty until the first release.
class StarterPhrasebookCatalog extends Equatable {
  new(Iterable<StarterPhrasebookInfo> packs, {this.release, this.source})
    : packs = List.unmodifiable(packs);

  /// Parses `phrasebook_catalog.json`. Throws [FormatException] when it is
  /// invalid (another schema, duplicate ids, an invalid pack).
  factory parse(String text) {
    final json = jsonDecode(text);
    if (json is! Map<String, Object?>) {
      throw const FormatException('The catalog must be a JSON object');
    }
    if (json['schemaVersion'] != supportedSchemaVersion) {
      throw FormatException('Unsupported schema', json['schemaVersion']);
    }
    final packs = json['packs'];
    if (packs is! List<Object?>) throw const FormatException('Missing packs');
    final parsed = [
      for (final pack in packs)
        if (pack is Map<String, Object?>)
          StarterPhrasebookInfo.fromJson(pack)
        else
          throw FormatException('Invalid pack', pack),
    ];
    if (parsed.map((pack) => pack.id).toSet().length != parsed.length) {
      throw const FormatException('Duplicate phrasebook ids');
    }
    return StarterPhrasebookCatalog(
      parsed..sort((a, b) => a.name.compareTo(b.name)),
      release: json['release'] as String?,
      source: json['source'] as String?,
    );
  }

  static const supportedSchemaVersion = 1;

  /// Every pack, sorted by name.
  final List<StarterPhrasebookInfo> packs;

  /// The release, e.g. `phrasebooks-2026-10-22`.
  final String? release;

  /// The release's page.
  final String? source;

  bool get isEmpty => packs.isEmpty;

  /// The pack with [id], if any.
  StarterPhrasebookInfo? byId(String id) =>
      packs.where((pack) => pack.id == id).firstOrNull;

  @override
  List<Object?> get props => [packs, release, source];
}

/// What is known of an installed starter phrasebook without reading it.
class InstalledStarterPhrasebook extends Equatable {
  const new({
    required this.id,
    required this.language,
    required this.baseLanguage,
    required this.name,
    required this.sha256,
    required this.size,
    required this.phrases,
    required this.installedAt,
  });

  factory fromJson(Map<String, Object?> json) {
    if (json
        case {
          'id': final String id,
          'language': final String language,
          'baseLanguage': final String baseLanguage,
          'name': final String name,
          'sha256': final String sha256,
          'size': final int size,
          'phrases': final int phrases,
        }
        when _hexSha256.hasMatch(sha256)) {
      return InstalledStarterPhrasebook(
        id: id,
        language: language,
        baseLanguage: baseLanguage,
        name: name,
        sha256: sha256,
        size: size,
        phrases: phrases,
        installedAt:
            Phrase.parseTime(json['installedAt']) ??
            DateTime.fromMillisecondsSinceEpoch(0),
      );
    }
    throw FormatException('Invalid installed phrasebook', json);
  }

  final String id;
  final String language;
  final String baseLanguage;
  final String name;

  /// SHA-256 of the stored file (as downloaded).
  final String sha256;
  final int size;
  final int phrases;
  final DateTime installedAt;

  Map<String, Object?> toJson() => {
    'id': id,
    'language': language,
    'baseLanguage': baseLanguage,
    'name': name,
    'sha256': sha256,
    'size': size,
    'phrases': phrases,
    'installedAt': installedAt.toUtc().toIso8601String(),
  };

  @override
  List<Object?> get props => [
    id,
    language,
    baseLanguage,
    name,
    sha256,
    size,
    phrases,
    installedAt,
  ];
}

/// An installed starter phrasebook: Wikivoyage's phrasebook for
/// [language], as `tool/phrasebooks.py build` writes it (gzip'd JSON, see
/// docs/phrasebook.md), with the attribution its licence asks for.
class StarterPhrasebook extends Equatable {
  const new({
    required this.id,
    required this.language,
    required this.baseLanguage,
    required this.name,
    required this.phrases,
    this.title = '',
    this.source = 'Wikivoyage',
    this.sourceUrl = '',
    this.revision = 0,
    this.revisionUrl = '',
    this.authorsUrl = '',
    this.license = 'CC BY-SA 4.0',
    this.licenseUrl = 'https://creativecommons.org/licenses/by-sa/4.0/',
    this.retrieved = '',
    this.attribution = '',
  });

  /// Parses a pack. [installedAt] becomes the phrases' times. Throws
  /// [FormatException] when it is not a phrasebook pack of a supported
  /// version, or has no phrases.
  factory fromJson(Map<String, Object?> json, {required DateTime installedAt}) {
    if (json['format'] != format) {
      throw FormatException('Not a Mozhi phrasebook', json['format']);
    }
    final version = json['formatVersion'];
    if (version is! int || version < 1 || version > formatVersion) {
      throw FormatException('Unsupported phrasebook version', version);
    }
    final id = json['id'];
    if (id is! String || !_id.hasMatch(id)) {
      throw FormatException('Invalid phrasebook id', id);
    }
    final language = _string(json, 'language');
    final baseLanguage = _string(json, 'baseLanguage', fallback: 'en');
    final sections = json['sections'];
    if (sections is! List<Object?>) {
      throw const FormatException('Missing sections');
    }
    final phrases = <Phrase>[];
    final ids = <String>{};
    for (final section in sections) {
      if (section is! Map<String, Object?>) continue;
      final topic = _string(section, 'title', fallback: '');
      final items = section['phrases'];
      if (items is! List<Object?>) continue;
      for (final item in items) {
        if (item
            case {
              'id': final String phraseId,
              'text': final String text,
              'translation': final String translation,
            }
            when phraseId.isNotEmpty &&
                text.trim().isNotEmpty &&
                translation.trim().isNotEmpty) {
          final full = Phrase.starterId(id, phraseId);
          if (!ids.add(full)) continue;
          phrases.add(
            Phrase(
              id: full,
              text: text.trim(),
              translation: translation.trim(),
              sourceCode: baseLanguage,
              targetCode: language,
              createdAt: installedAt,
              updatedAt: installedAt,
              origin: PhraseOrigin.starter,
              pronunciation: switch (item['pronunciation']) {
                final String value => value.trim(),
                _ => '',
              },
              topic: topic.trim(),
            ),
          );
        }
      }
    }
    if (phrases.isEmpty) throw const FormatException('No phrases');
    return StarterPhrasebook(
      id: id,
      language: language,
      baseLanguage: baseLanguage,
      name: _string(json, 'name'),
      title: _string(json, 'title', fallback: ''),
      source: _string(json, 'source', fallback: 'Wikivoyage'),
      sourceUrl: _string(json, 'sourceUrl', fallback: ''),
      revision: switch (json['revision']) {
        final int value => value,
        _ => 0,
      },
      revisionUrl: _string(json, 'revisionUrl', fallback: ''),
      authorsUrl: _string(json, 'authorsUrl', fallback: ''),
      license: _string(json, 'license', fallback: 'CC BY-SA 4.0'),
      licenseUrl: _string(
        json,
        'licenseUrl',
        fallback: 'https://creativecommons.org/licenses/by-sa/4.0/',
      ),
      retrieved: _string(json, 'retrieved', fallback: ''),
      attribution: _string(json, 'attribution', fallback: ''),
      phrases: List.unmodifiable(phrases),
    );
  }

  /// The `format` of a pack.
  static const format = 'mozhi-phrasebook';

  /// The newest pack version the app reads.
  static const formatVersion = 1;

  final String id;

  /// The language of the translations.
  final String language;

  /// The language of the phrases.
  final String baseLanguage;

  /// English name of [language].
  final String name;

  /// The Wikivoyage page's title ("Portuguese phrasebook").
  final String title;

  /// "Wikivoyage".
  final String source;

  /// The page.
  final String sourceUrl;

  /// The revision the pack was made from.
  final int revision;

  /// The page at that revision.
  final String revisionUrl;

  /// The page's history: its authors.
  final String authorsUrl;
  final String license;
  final String licenseUrl;

  /// When the page was read (`yyyy-MM-dd`).
  final String retrieved;

  /// The credit line (who wrote it, what was changed).
  final String attribution;

  /// The phrases, in the page's order ([Phrase.topic]: its section).
  final List<Phrase> phrases;

  @override
  List<Object?> get props => [id, revision, phrases];
}

final _id = RegExp(r'^[a-z]{2,3}(-[a-z0-9]{2,8})*$');
final _hexSha256 = RegExp(r'^[0-9a-f]{64}$');

String _string(Map<String, Object?> json, String key, {String? fallback}) {
  final value = json[key];
  if (value is String && (value.isNotEmpty || fallback != null)) return value;
  if (value == null && fallback != null) return fallback;
  throw FormatException('Missing "$key"', json);
}
