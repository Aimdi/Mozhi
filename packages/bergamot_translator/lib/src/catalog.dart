import 'dart:convert';

import 'package:meta/meta.dart';

/// The files of one translation direction.
enum ModelFileKind {
  /// The quantized model (`model.<pair>.intgemm.alphas.bin`).
  model('model'),

  /// The lexical shortlist (`lex.50.50.<pair>.s2t.bin`).
  lexicalShortlist('lexicalShortlist'),

  /// A vocabulary shared by source and target (`vocab.<pair>.spm`).
  vocab('vocab'),

  /// The source vocabulary of a model with split vocabularies.
  srcVocab('srcVocab'),

  /// The target vocabulary of a model with split vocabularies.
  trgVocab('trgVocab');

  new(this.key);

  /// The key in `catalog.json` and in installed manifests.
  final String key;

  static ModelFileKind? fromKey(String key) {
    for (final kind in values) {
      if (kind.key == key) return kind;
    }
    return null;
  }
}

/// One gzip-compressed file of a [CatalogModel].
@immutable
final class CatalogFile {
  const new({
    required this.kind,
    required this.name,
    required this.url,
    required this.size,
    required this.sha256,
    required this.uncompressedSize,
    required this.uncompressedSha256,
  });

  factory fromJson(ModelFileKind kind, Map<String, Object?> json) {
    final name = _string(json, 'name');
    if (!_safeName.hasMatch(name) || name.startsWith('.')) {
      throw FormatException('Unsafe file name', name);
    }
    final url = Uri.tryParse(_string(json, 'url'));
    if (url == null || !url.isScheme('https') || url.host.isEmpty) {
      throw FormatException('Model URLs must be https', json['url']);
    }
    return CatalogFile(
      kind: kind,
      name: name,
      url: url,
      size: _positiveInt(json, 'size'),
      sha256: _sha256(json, 'sha256'),
      uncompressedSize: _positiveInt(json, 'uncompressedSize'),
      uncompressedSha256: _sha256(json, 'uncompressedSha256'),
    );
  }

  final ModelFileKind kind;

  /// File name once installed (uncompressed), e.g. `vocab.ende.spm`.
  final String name;

  /// Where the gzip-compressed file is downloaded from.
  final Uri url;

  /// Bytes of the download (gzip).
  final int size;

  /// Lower-case hex SHA-256 of the download (gzip), checked before it is
  /// decompressed.
  final String sha256;

  /// Bytes once decompressed.
  final int uncompressedSize;

  /// Lower-case hex SHA-256 of the decompressed file.
  final String uncompressedSha256;

  Map<String, Object?> toJson() => {
    'name': name,
    'url': url.toString(),
    'size': size,
    'sha256': sha256,
    'uncompressedSize': uncompressedSize,
    'uncompressedSha256': uncompressedSha256,
  };

  @override
  bool operator ==(Object other) =>
      other is CatalogFile &&
      other.kind == kind &&
      other.name == name &&
      other.url == url &&
      other.size == size &&
      other.sha256 == sha256 &&
      other.uncompressedSize == uncompressedSize &&
      other.uncompressedSha256 == uncompressedSha256;

  @override
  int get hashCode => Object.hash(kind, name, url, size, sha256);
}

/// One translation direction (e.g. `en` -> `de`) from Mozilla's registry.
@immutable
final class CatalogModel {
  const new({
    required this.source,
    required this.target,
    required this.version,
    required this.files,
    this.architecture,
    this.releaseStatus,
  });

  factory fromJson(Map<String, Object?> json) {
    final source = _string(json, 'source');
    final target = _string(json, 'target');
    for (final code in [source, target]) {
      if (!_modelLanguage.hasMatch(code)) {
        throw FormatException('Invalid language code', code);
      }
    }
    if (source == target) {
      throw FormatException('Source equals target', source);
    }
    final version = _string(json, 'version');
    if (!_safeName.hasMatch(version) || version.startsWith('.')) {
      throw FormatException('Unsafe model version', version);
    }
    final rawFiles = json['files'];
    if (rawFiles is! Map<String, Object?>) {
      throw FormatException('Missing files for $source-$target', json);
    }
    final files = <ModelFileKind, CatalogFile>{};
    for (final MapEntry(:key, :value) in rawFiles.entries) {
      final kind = ModelFileKind.fromKey(key);
      if (kind == null) {
        throw FormatException('Unknown file kind for $source-$target', key);
      }
      if (value is! Map<String, Object?>) {
        throw FormatException('Invalid $key for $source-$target', value);
      }
      files[kind] = CatalogFile.fromJson(kind, value);
    }
    final hasVocab =
        files.containsKey(ModelFileKind.vocab) ||
        (files.containsKey(ModelFileKind.srcVocab) &&
            files.containsKey(ModelFileKind.trgVocab));
    if (!files.containsKey(ModelFileKind.model) ||
        !files.containsKey(ModelFileKind.lexicalShortlist) ||
        !hasVocab) {
      throw FormatException(
        'Incomplete files for $source-$target',
        files.keys.map((kind) => kind.key).toList(),
      );
    }
    final names = files.values.map((file) => file.name).toSet();
    if (names.length != files.length) {
      throw FormatException('Duplicate file names for $source-$target');
    }
    return CatalogModel(
      source: source,
      target: target,
      version: version,
      architecture: json['architecture'] as String?,
      releaseStatus: json['releaseStatus'] as String?,
      files: Map.unmodifiable(files),
    );
  }

  /// Mozilla language code of the source (e.g. `en`, `zh_hant`).
  final String source;

  /// Mozilla language code of the target.
  final String target;

  /// Mozilla's training-run id: unique per model and safe as a directory
  /// name. A new version of a direction gets a new id.
  final String version;

  /// `tiny`, `base` or `base-memory`.
  final String? architecture;

  /// `Release` or `Release Android`.
  final String? releaseStatus;

  final Map<ModelFileKind, CatalogFile> files;

  /// `<source>-<target>`, e.g. `en-de`.
  String get pair => '$source-$target';

  /// Bytes to download.
  int get downloadSize => files.values.fold(0, (sum, file) => sum + file.size);

  /// Bytes on disk once installed.
  int get installedSize =>
      files.values.fold(0, (sum, file) => sum + file.uncompressedSize);

  Map<String, Object?> toJson() => {
    'source': source,
    'target': target,
    'version': version,
    'architecture': ?architecture,
    'releaseStatus': ?releaseStatus,
    'files': {for (final file in files.values) file.kind.key: file.toJson()},
  };

  @override
  bool operator ==(Object other) =>
      other is CatalogModel &&
      other.source == source &&
      other.target == target &&
      other.version == version;

  @override
  int get hashCode => Object.hash(source, target, version);

  @override
  String toString() => 'CatalogModel($pair, $version)';
}

/// The downloadable models: `assets/catalog.json`, generated by
/// `tool/offline_catalog.py` from Mozilla's Firefox Translations registry.
@immutable
final class ModelCatalog {
  new(Iterable<CatalogModel> models)
    : models = List.unmodifiable(models),
      _byPair = {for (final model in models) model.pair: model};

  factory fromJson(Map<String, Object?> json) {
    final schema = json['schemaVersion'];
    if (schema != supportedSchemaVersion) {
      throw FormatException('Unsupported catalog schema', schema);
    }
    final models = json['models'];
    if (models is! List<Object?>) {
      throw const FormatException('Missing models');
    }
    final parsed = [
      for (final model in models)
        if (model is Map<String, Object?>)
          CatalogModel.fromJson(model)
        else
          throw FormatException('Invalid model', model),
    ];
    final pairs = parsed.map((model) => model.pair).toSet();
    if (pairs.length != parsed.length) {
      throw const FormatException('Duplicate language pairs');
    }
    return ModelCatalog(parsed);
  }

  /// Parses `catalog.json`. Throws [FormatException] when it is invalid.
  factory parse(String source) {
    final json = jsonDecode(source);
    if (json is! Map<String, Object?>) {
      throw const FormatException('The catalog must be a JSON object');
    }
    return ModelCatalog.fromJson(json);
  }

  static const supportedSchemaVersion = 1;

  /// Asset key of the bundled catalog.
  static const assetKey = 'packages/bergamot_translator/assets/catalog.json';

  final List<CatalogModel> models;
  final Map<String, CatalogModel> _byPair;

  /// The model for `source -> target` (Mozilla codes), if any.
  CatalogModel? model(String source, String target) =>
      _byPair['$source-$target'];

  Map<String, Object?> toJson() => {
    'schemaVersion': supportedSchemaVersion,
    'models': [for (final model in models) model.toJson()],
  };
}

final _safeName = RegExp(r'^[A-Za-z0-9._-]{1,200}$');
final _modelLanguage = RegExp(r'^[a-z]{2,3}(_[a-z]{2,8})?$');
final _hexSha256 = RegExp(r'^[0-9a-f]{64}$');

String _string(Map<String, Object?> json, String key) {
  final value = json[key];
  if (value is String && value.isNotEmpty) return value;
  throw FormatException('Missing "$key"', json);
}

int _positiveInt(Map<String, Object?> json, String key) {
  final value = json[key];
  if (value is int && value > 0) return value;
  throw FormatException('"$key" must be a positive integer', value);
}

String _sha256(Map<String, Object?> json, String key) {
  final value = json[key];
  if (value is String && _hexSha256.hasMatch(value)) return value;
  throw FormatException('"$key" must be a lower-case hex SHA-256', value);
}
