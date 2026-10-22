import 'dart:convert';

import 'package:meta/meta.dart';

// Where the models are downloaded from (Hugging Face or a mirror).
export 'package:whisper_speech/src/model_source.dart';

/// One downloadable Whisper model (a whisper.cpp `ggml-*.bin` file).
@immutable
final class WhisperCatalogModel {
  const new({
    required this.id,
    required this.name,
    required this.url,
    required this.size,
    required this.sha1,
    this.sha256,
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
    final sha256 = json['sha256'];
    if (sha256 != null &&
        (sha256 is! String || !_sha256Pattern.hasMatch(sha256))) {
      throw FormatException('Invalid SHA-256', sha256);
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
      sha256: sha256 as String?,
      multilingual: multilingual,
      parameters: parameters as int?,
    );
  }

  /// Short identifier, e.g. `tiny` or `base` (also the install folder).
  final String id;

  /// File name as published and installed, e.g. `ggml-tiny.bin`.
  final String name;

  /// Where the file is downloaded from by default (https; see
  /// `whisperDownloadUrls` for mirrors).
  final Uri url;

  /// Exact bytes of the file, checked while downloading.
  final int size;

  /// Lower-case hex SHA-1 of the file (as published by whisper.cpp).
  final String sha1;

  /// Lower-case hex SHA-256 of the file (as Hugging Face reports it), when
  /// the catalog has it: checked as well as [sha1], so that a mirror
  /// cannot pass off another file.
  final String? sha256;

  /// Whether the model knows the 99 Whisper languages (else English only).
  final bool multilingual;

  /// Approximate number of parameters, when known.
  final int? parameters;

  static final _safeId = RegExp(r'^[a-z0-9][a-z0-9_.-]{0,31}$');
  static final _safeName = RegExp(r'^[A-Za-z0-9._-]+$');
  static final _sha1Pattern = RegExp(r'^[0-9a-f]{40}$');
  static final _sha256Pattern = RegExp(r'^[0-9a-f]{64}$');

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
      other.sha256 == sha256 &&
      other.multilingual == multilingual &&
      other.parameters == parameters;

  @override
  int get hashCode =>
      Object.hash(id, name, url, size, sha1, sha256, multilingual, parameters);

  @override
  String toString() => 'WhisperCatalogModel($id, $name)';
}

/// The Whisper models that can be downloaded (`assets/models.json`), from
/// the fastest to the most accurate, and the voice activity detection
/// model ([vad]).
@immutable
final class WhisperModelCatalog {
  const new({required this.models, this.vad, this.source, this.license});

  /// Parses `models.json`. Throws [FormatException] when it is invalid
  /// (unknown schema, unsafe names, non-https URLs, duplicate ids, an
  /// unknown `kind`, more than one VAD model, no speech model).
  ///
  /// Entries are speech models unless their `kind` is `vad` (the [vad]
  /// model, listed with them so that tools reading `models` see it too).
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
    WhisperCatalogModel? vad;
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
      switch (entry['kind'] ?? 'speech') {
        case 'speech':
          models.add(model);
        case 'vad' when vad == null:
          vad = model;
        case 'vad':
          throw FormatException('More than one VAD model', model.id);
        case final kind:
          throw FormatException('Unknown model kind', kind);
      }
    }
    if (models.isEmpty) {
      throw const FormatException('The catalog has no speech models');
    }
    return WhisperModelCatalog(
      models: List.unmodifiable(models),
      vad: vad,
      source: json['source'] as String?,
      license: json['license'] as String?,
    );
  }

  /// `models.json` schema this code reads.
  static const schemaVersion = 1;

  /// Asset key of the bundled catalog (see `loadBundledWhisperCatalog`).
  static const assetKey = 'packages/whisper_speech/assets/models.json';

  /// The speech models, from the fastest (smallest) to the most accurate
  /// (largest).
  final List<WhisperCatalogModel> models;

  /// The Silero voice activity detection model (`kind: vad`): tells speech
  /// from silence and noise while recording (`WhisperSpeech.detectSpeech`).
  /// Downloaded with a speech model; null when the catalog has none.
  final WhisperCatalogModel? vad;

  /// Where the models are published, e.g. the Hugging Face repository.
  final String? source;

  /// License of the model weights.
  final String? license;

  /// The speech model with [id], if listed ([vad] is not one).
  WhisperCatalogModel? model(String id) {
    for (final model in models) {
      if (model.id == id) return model;
    }
    return null;
  }
}
