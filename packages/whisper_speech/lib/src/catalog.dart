import 'dart:convert';

import 'package:meta/meta.dart';

/// One downloadable Whisper model (a whisper.cpp `ggml-*.bin` file).
@immutable
final class WhisperCatalogModel {
  const new({
    required this.id,
    required this.name,
    required this.url,
    required this.size,
    required this.sha1,
    this.multilingual = true,
    this.parameters,
  });

  factory fromJson(Map<String, Object?> json) {
    final id = _string(json, 'id');
    if (!_safeId.hasMatch(id)) throw FormatException('Unsafe model id', id);
    final name = _string(json, 'name');
    if (!_safeName.hasMatch(name) || name.startsWith('.')) {
      throw FormatException('Unsafe file name', name);
    }
    final url = Uri.tryParse(_string(json, 'url'));
    if (url == null || !url.isScheme('https') || url.host.isEmpty) {
      throw FormatException('Model URLs must be https', json['url']);
    }
    final sha1 = _string(json, 'sha1');
    if (!_sha1Pattern.hasMatch(sha1)) {
      throw FormatException('Invalid SHA-1', sha1);
    }
    final size = json['size'];
    if (size is! int || size <= 0) {
      throw FormatException('Invalid size', size);
    }
    final multilingual = json['multilingual'] ?? true;
    if (multilingual is! bool) {
      throw FormatException('Invalid multilingual flag', multilingual);
    }
    final parameters = json['parameters'];
    if (parameters != null && (parameters is! int || parameters <= 0)) {
      throw FormatException('Invalid parameter count', parameters);
    }
    return WhisperCatalogModel(
      id: id,
      name: name,
      url: url,
      size: size,
      sha1: sha1,
      multilingual: multilingual,
      parameters: parameters as int?,
    );
  }

  /// Short identifier, e.g. `tiny` or `base` (also the install folder).
  final String id;

  /// File name as published and installed, e.g. `ggml-tiny.bin`.
  final String name;

  /// Where the file is downloaded from (https).
  final Uri url;

  /// Exact bytes of the file, checked while downloading.
  final int size;

  /// Lower-case hex SHA-1 of the file (as published by whisper.cpp).
  final String sha1;

  /// Whether the model knows the 99 Whisper languages (else English only).
  final bool multilingual;

  /// Approximate number of parameters, when known.
  final int? parameters;

  static final _safeId = RegExp(r'^[a-z0-9][a-z0-9_.-]{0,31}$');
  static final _safeName = RegExp(r'^[A-Za-z0-9._-]+$');
  static final _sha1Pattern = RegExp(r'^[0-9a-f]{40}$');

  static String _string(Map<String, Object?> json, String key) {
    final value = json[key];
    if (value is! String || value.isEmpty) {
      throw FormatException('Missing "$key"', json);
    }
    return value;
  }

  @override
  bool operator ==(Object other) =>
      other is WhisperCatalogModel &&
      other.id == id &&
      other.name == name &&
      other.url == url &&
      other.size == size &&
      other.sha1 == sha1 &&
      other.multilingual == multilingual &&
      other.parameters == parameters;

  @override
  int get hashCode =>
      Object.hash(id, name, url, size, sha1, multilingual, parameters);

  @override
  String toString() => 'WhisperCatalogModel($id, $name)';
}

/// The Whisper models that can be downloaded (`assets/models.json`), from
/// the fastest to the most accurate.
@immutable
final class WhisperModelCatalog {
  const new({required this.models, this.source, this.license});

  /// Parses `models.json`. Throws [FormatException] when it is invalid
  /// (unknown schema, unsafe names, non-https URLs, duplicate ids).
  factory parse(String source) {
    final json = jsonDecode(source);
    if (json is! Map<String, Object?>) {
      throw const FormatException('The catalog must be a JSON object');
    }
    if (json['schemaVersion'] != schemaVersion) {
      throw FormatException(
        'Unsupported catalog schema',
        json['schemaVersion'],
      );
    }
    final entries = json['models'];
    if (entries is! List<Object?> || entries.isEmpty) {
      throw const FormatException('The catalog has no models');
    }
    final models = <WhisperCatalogModel>[];
    final ids = <String>{};
    final names = <String>{};
    for (final entry in entries) {
      if (entry is! Map<String, Object?>) {
        throw FormatException('Invalid model entry', entry);
      }
      final model = WhisperCatalogModel.fromJson(entry);
      if (!ids.add(model.id) || !names.add(model.name.toLowerCase())) {
        throw FormatException('Duplicate model', model.id);
      }
      models.add(model);
    }
    return WhisperModelCatalog(
      models: List.unmodifiable(models),
      source: json['source'] as String?,
      license: json['license'] as String?,
    );
  }

  /// `models.json` schema this code reads.
  static const schemaVersion = 1;

  /// Asset key of the bundled catalog (see `loadBundledWhisperCatalog`).
  static const assetKey = 'packages/whisper_speech/assets/models.json';

  /// From the fastest (smallest) to the most accurate (largest).
  final List<WhisperCatalogModel> models;

  /// Where the models are published, e.g. the Hugging Face repository.
  final String? source;

  /// License of the model weights.
  final String? license;

  /// The model with [id], if listed.
  WhisperCatalogModel? model(String id) {
    for (final model in models) {
      if (model.id == id) return model;
    }
    return null;
  }
}
