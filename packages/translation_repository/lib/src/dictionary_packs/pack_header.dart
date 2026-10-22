import 'dart:convert';
import 'dart:typed_data';

import 'package:meta/meta.dart';

/// Where a dictionary's data comes from and under which licence, for the
/// credit and the licence link the data's licence requires (Wiktionary's
/// CC BY-SA 4.0).
@immutable
final class DictionaryAttribution {
  const new({
    required this.source,
    required this.license,
    this.sourceUrl = '',
    this.licenseUrl = '',
    this.text = '',
    this.snapshot = '',
  });

  /// E.g. `Wiktionary`.
  final String source;

  /// E.g. `https://en.wiktionary.org/`.
  final String sourceUrl;

  /// E.g. `CC BY-SA 4.0`.
  final String license;

  /// E.g. `https://creativecommons.org/licenses/by-sa/4.0/`.
  final String licenseUrl;

  /// The full credit: authors, source, extraction, changes (English).
  final String text;

  /// Date of the data (`YYYY-MM-DD`), when known.
  final String snapshot;

  @override
  bool operator ==(Object other) =>
      other is DictionaryAttribution &&
      other.source == source &&
      other.sourceUrl == sourceUrl &&
      other.license == license &&
      other.licenseUrl == licenseUrl &&
      other.text == text &&
      other.snapshot == snapshot;

  @override
  int get hashCode =>
      Object.hash(source, sourceUrl, license, licenseUrl, text, snapshot);

  @override
  String toString() => 'DictionaryAttribution($source, $license)';
}

/// The metadata at the start of a dictionary pack.
///
/// A pack file is:
///
/// | Bytes | Content |
/// | --- | --- |
/// | 0-7 | [magic], ASCII `MOZHIDCT` |
/// | 8-9 | [formatVersion], little-endian |
/// | 10-11 | reserved (0) |
/// | 12-15 | length *M* of the metadata, little-endian |
/// | 16 to 16+*M* | the metadata: this header as UTF-8 JSON ([toJson]) |
/// | the rest | the data section ([dataLength] bytes, SHA-256 [sha256]) |
///
/// The data section holds gzip'd entry blocks, gzip'd key index blocks,
/// the key [directory] and the entry block table ([blocks]); see
/// `docs/dictionary-packs.md` for their layout.
@immutable
final class DictionaryPackHeader {
  const new({
    required this.language,
    required this.entryCount,
    required this.keyCount,
    required this.directory,
    required this.blocks,
    required this.dataLength,
    required this.sha256,
    this.format = formatVersion,
    this.glossLanguage = 'en',
    this.name = '',
    this.source = 'Wiktionary',
    this.sourceUrl = '',
    this.extractor = '',
    this.snapshot = '',
    this.license = 'CC BY-SA 4.0',
    this.licenseUrl = '',
    this.attributionText = '',
    this.targets = const [],
    this.blockSize = defaultBlockSize,
    this.fold = const {},
  });

  factory fromJson(Object? json) {
    if (json is! Map<String, Object?>) {
      throw const FormatException('The pack metadata must be an object');
    }
    final format = json['format'];
    if (format != formatVersion) {
      throw FormatException('Unsupported pack format', format);
    }
    final fold = json['fold'] ?? const <String, Object?>{};
    if (fold is! Map<String, Object?> ||
        fold.values.any((value) => value is! String)) {
      throw FormatException('Invalid fold table', fold);
    }
    final layout = json['layout'];
    if (layout is! Map<String, Object?>) {
      throw FormatException('Invalid layout', layout);
    }
    final sha256 = _string(json, 'sha256');
    if (!_hexSha256.hasMatch(sha256)) {
      throw FormatException('Invalid SHA-256', sha256);
    }
    final language = _string(json, 'language');
    if (language.isEmpty) throw const FormatException('Missing "language"');
    return DictionaryPackHeader(
      language: language,
      glossLanguage: _string(json, 'glossLanguage', fallback: 'en'),
      name: _string(json, 'name'),
      source: _string(json, 'source'),
      sourceUrl: _string(json, 'sourceUrl'),
      extractor: _string(json, 'extractor'),
      snapshot: _string(json, 'snapshot'),
      license: _string(json, 'license'),
      licenseUrl: _string(json, 'licenseUrl'),
      attributionText: _string(json, 'attribution'),
      targets: switch (json['targets']) {
        null => const [],
        final List<Object?> list when list.every((code) => code is String) =>
          List.unmodifiable(list.cast<String>()),
        final other => throw FormatException('Invalid targets', other),
      },
      entryCount: _int(json, 'entries'),
      keyCount: _int(json, 'keys'),
      blockSize: _int(json, 'blockSize'),
      fold: Map.unmodifiable(fold.cast<String, String>()),
      directory: _range(layout, 'directory'),
      blocks: _range(layout, 'blocks'),
      dataLength: _int(json, 'dataLength'),
      sha256: sha256,
    );
  }

  /// The first bytes of every pack.
  static const magic = 'MOZHIDCT';

  /// The format this reader and writer use.
  static const formatVersion = 1;

  /// Bytes before the metadata: [magic], version, reserved, length.
  static const int prefixLength = 16;

  /// Most uncompressed bytes in an entry or key index block.
  static const int defaultBlockSize = 64 * 1024;

  /// Longest metadata a reader accepts.
  static const int maxMetadataLength = 1 << 20;

  final int format;

  /// Language of the words (an app language code, e.g. `es`).
  final String language;

  /// Language of the definitions (`en` for English Wiktionary).
  final String glossLanguage;

  /// English name of [language], e.g. `Spanish`.
  final String name;
  final String source;
  final String sourceUrl;

  /// The tool that extracted the data, e.g. `wiktextract (kaikki.org)`.
  final String extractor;

  /// Date of the data (`YYYY-MM-DD`).
  final String snapshot;
  final String license;
  final String licenseUrl;

  /// The full credit (see [DictionaryAttribution.text]).
  final String attributionText;

  /// Language codes the entries have translations into.
  final List<String> targets;
  final int entryCount;

  /// Distinct lookup keys (headwords and inflected forms, folded).
  final int keyCount;
  final int blockSize;

  /// The fold table of `DictionaryKeyFolder`: one character to its folded
  /// text.
  final Map<String, String> fold;

  /// Offset (in the data section) and length of the key directory.
  final ({int offset, int length}) directory;

  /// Offset (in the data section) and length of the entry block table.
  final ({int offset, int length}) blocks;

  /// Bytes of the data section.
  final int dataLength;

  /// Lower-case hex SHA-256 of the data section.
  final String sha256;

  DictionaryAttribution get attribution => DictionaryAttribution(
    source: source,
    sourceUrl: sourceUrl,
    license: license,
    licenseUrl: licenseUrl,
    text: attributionText,
    snapshot: snapshot,
  );

  Map<String, Object?> toJson() => {
    'format': format,
    'language': language,
    'glossLanguage': glossLanguage,
    'name': name,
    'source': source,
    'sourceUrl': sourceUrl,
    'extractor': extractor,
    'snapshot': snapshot,
    'license': license,
    'licenseUrl': licenseUrl,
    'attribution': attributionText,
    'targets': targets,
    'entries': entryCount,
    'keys': keyCount,
    'blockSize': blockSize,
    'fold': fold,
    'layout': {
      'directory': [directory.offset, directory.length],
      'blocks': [blocks.offset, blocks.length],
    },
    'dataLength': dataLength,
    'sha256': sha256,
  };

  /// The bytes before the data section: the prefix and the metadata.
  Uint8List encode() {
    final metadata = utf8.encode(jsonEncode(toJson()));
    final bytes = Uint8List(prefixLength + metadata.length)
      ..setRange(0, magic.length, ascii.encode(magic))
      ..setRange(prefixLength, prefixLength + metadata.length, metadata);
    ByteData.sublistView(bytes)
      ..setUint16(8, format, Endian.little)
      ..setUint32(12, metadata.length, Endian.little);
    return bytes;
  }

  /// The metadata length from the first [prefixLength] bytes of a pack.
  /// Throws [FormatException] when they are not a pack's.
  static int metadataLength(Uint8List prefix) {
    if (prefix.length < prefixLength ||
        ascii.decode(prefix.sublist(0, magic.length), allowInvalid: true) !=
            magic) {
      throw const FormatException('Not a dictionary pack');
    }
    final data = ByteData.sublistView(prefix);
    final version = data.getUint16(8, Endian.little);
    if (version != formatVersion) {
      throw FormatException('Unsupported pack format', version);
    }
    final length = data.getUint32(12, Endian.little);
    if (length == 0 || length > maxMetadataLength) {
      throw FormatException('Invalid metadata length', length);
    }
    return length;
  }
}

final _hexSha256 = RegExp(r'^[0-9a-f]{64}$');

String _string(Map<String, Object?> json, String key, {String fallback = ''}) =>
    switch (json[key]) {
      null => fallback,
      final String value => value,
      final other => throw FormatException('"$key" must be a string', other),
    };

int _int(Map<String, Object?> json, String key) => switch (json[key]) {
  final int value when value >= 0 => value,
  final other => throw FormatException('"$key" must be a count', other),
};

({int offset, int length}) _range(Map<String, Object?> json, String key) =>
    switch (json[key]) {
      [final int offset, final int length] when offset >= 0 && length >= 0 => (
        offset: offset,
        length: length,
      ),
      final other => throw FormatException('Invalid "$key" range', other),
    };
