import 'dart:convert';

import 'package:meta/meta.dart';

/// What an on-device model is for.
enum LlamaModelRole {
  /// A translation model (Hy-MT2): translates with its own fixed prompts
  /// and does nothing else.
  translation,

  /// A general model (Gemma 4, Qwen3) for the AI extras: refine,
  /// alternatives, insights, dictionary, explain, proofread, meaning check.
  assistant;

  /// The role called [name]; null for any other value.
  static LlamaModelRole? tryParse(Object? name) {
    for (final role in values) {
      if (role.name == name) return role;
    }
    return null;
  }
}

/// The sampling a model's publisher recommends (`sampling` in
/// `models.json`); null fields leave the engine's default.
@immutable
final class LlamaCatalogSampling {
  const new({
    this.temperature,
    this.topP,
    this.topK,
    this.minP,
    this.repeatPenalty,
  });

  /// Reads the `sampling` object. Throws [FormatException] for an unknown
  /// key or a value out of range (temperature 0-2, topP and minP 0-1,
  /// topK 0-1000, repeatPenalty 0.5-2).
  factory fromJson(Map<String, Object?> json) {
    for (final key in json.keys) {
      if (!_keys.contains(key)) {
        throw FormatException('Unknown sampling parameter', key);
      }
    }
    double? fraction(String key, double max, {double min = 0}) {
      final value = json[key];
      if (value == null) return null;
      if (value is! num || value < min || value > max) {
        throw FormatException('Invalid $key', value);
      }
      return value.toDouble();
    }

    final topK = json['topK'];
    if (topK != null && (topK is! int || topK < 0 || topK > 1000)) {
      throw FormatException('Invalid topK', topK);
    }
    return LlamaCatalogSampling(
      temperature: fraction('temperature', 2),
      topP: fraction('topP', 1),
      topK: topK as int?,
      minP: fraction('minP', 1),
      repeatPenalty: fraction('repeatPenalty', 2, min: 0.5),
    );
  }

  static const _keys = {'temperature', 'topP', 'topK', 'minP', 'repeatPenalty'};

  /// Softmax temperature (0 is greedy).
  final double? temperature;

  /// Nucleus sampling: the smallest set of tokens whose probabilities add
  /// up to this.
  final double? topP;

  /// Only the [topK] most likely tokens (0: all).
  final int? topK;

  /// Tokens less likely than this fraction of the most likely one are
  /// dropped.
  final double? minP;

  /// Penalty for repeating recent tokens (1: none).
  final double? repeatPenalty;

  Map<String, Object?> toJson() => {
    'temperature': ?temperature,
    'topP': ?topP,
    'topK': ?topK,
    'minP': ?minP,
    'repeatPenalty': ?repeatPenalty,
  };

  @override
  bool operator ==(Object other) =>
      other is LlamaCatalogSampling &&
      other.temperature == temperature &&
      other.topP == topP &&
      other.topK == topK &&
      other.minP == minP &&
      other.repeatPenalty == repeatPenalty;

  @override
  int get hashCode => Object.hash(temperature, topP, topK, minP, repeatPenalty);
}

/// One downloadable on-device model: a llama.cpp GGUF file pinned by size
/// and SHA-256, with what the app needs to offer and run it.
@immutable
final class LlamaCatalogModel {
  const new({
    required this.id,
    required this.name,
    required this.url,
    required this.size,
    required this.sha256,
    required this.role,
    required this.family,
    required this.promptProfile,
    required this.displayName,
    required this.license,
    required this.licenseUrl,
    required this.sourceUrl,
    this.parameters = '',
    this.quantization = '',
    this.contextSize = 4096,
    this.minRamMb = 0,
    this.recommendedRamMb = 0,
    this.languages = const [],
    this.sampling = const LlamaCatalogSampling(),
  });

  /// Reads one entry of `models.json`. Throws [FormatException] for
  /// anything the app should not download or run: an unsafe id or file
  /// name (only `.gguf` files), a URL that is not `https` or does not end
  /// in [name], a size or SHA-256 that is not one, an unknown [role],
  /// [family] or [promptProfile], a missing licence or source, memory
  /// figures out of order, invalid language codes (a translation model
  /// needs some) or sampling out of range.
  factory fromJson(Map<String, Object?> json) {
    final id = _string(json, 'id');
    if (!isSafeId(id)) throw FormatException('Unsafe model id', id);
    final name = _string(json, 'name');
    if (!_safeName.hasMatch(name) ||
        name.startsWith('.') ||
        !name.toLowerCase().endsWith('.gguf')) {
      throw FormatException('Unsafe file name (a .gguf file)', name);
    }
    final url = _https(json, 'url');
    if (url.hasQuery ||
        url.hasFragment ||
        url.pathSegments.isEmpty ||
        url.pathSegments.last != name) {
      throw FormatException('The model URL must end in its file name', url);
    }
    final size = json['size'];
    if (size is! int || size <= 0) {
      throw FormatException('Invalid size', size);
    }
    final sha256 = _string(json, 'sha256');
    if (!_sha256Pattern.hasMatch(sha256)) {
      throw FormatException('Invalid SHA-256', sha256);
    }
    final role = LlamaModelRole.tryParse(json['role']);
    if (role == null) throw FormatException('Unknown role', json['role']);
    final family = _string(json, 'family');
    if (!families.contains(family)) {
      throw FormatException('Unknown model family', family);
    }
    final promptProfile = _string(json, 'promptProfile');
    if (!promptProfiles.contains(promptProfile)) {
      throw FormatException('Unknown prompt profile', promptProfile);
    }
    final displayName = _string(json, 'displayName');
    if (displayName.length > 64 || displayName.contains(_control)) {
      throw FormatException('Invalid display name', displayName);
    }
    final parameters = _string(json, 'parameters');
    if (parameters.length > 32 || parameters.contains(_control)) {
      throw FormatException('Invalid parameter count', parameters);
    }
    final quantization = _string(json, 'quantization');
    if (!_quantizationPattern.hasMatch(quantization)) {
      throw FormatException('Invalid quantization', quantization);
    }
    final contextSize = json['contextSize'];
    if (contextSize is! int || contextSize < 256 || contextSize > 131072) {
      throw FormatException('Invalid context size', contextSize);
    }
    final minRamMb = json['minRamMb'];
    final recommendedRamMb = json['recommendedRamMb'];
    if (minRamMb is! int || minRamMb <= 0) {
      throw FormatException('Invalid minRamMb', minRamMb);
    }
    if (recommendedRamMb is! int || recommendedRamMb < minRamMb) {
      throw FormatException('Invalid recommendedRamMb', recommendedRamMb);
    }
    final languages = _languages(json['languages'] ?? const <Object?>[]);
    if (role == LlamaModelRole.translation && languages.isEmpty) {
      throw FormatException('A translation model needs languages', id);
    }
    final license = _string(json, 'license');
    if (!_licensePattern.hasMatch(license)) {
      throw FormatException('Invalid license', license);
    }
    final sampling = switch (json['sampling']) {
      null => const LlamaCatalogSampling(),
      final Map<String, Object?> map => LlamaCatalogSampling.fromJson(map),
      final other => throw FormatException('Invalid sampling', other),
    };
    return LlamaCatalogModel(
      id: id,
      name: name,
      url: url,
      size: size,
      sha256: sha256,
      role: role,
      family: family,
      promptProfile: promptProfile,
      displayName: displayName,
      parameters: parameters,
      quantization: quantization,
      contextSize: contextSize,
      minRamMb: minRamMb,
      recommendedRamMb: recommendedRamMb,
      languages: languages,
      license: license,
      licenseUrl: _https(json, 'licenseUrl'),
      sourceUrl: _https(json, 'sourceUrl'),
      sampling: sampling,
    );
  }

  /// Short identifier, e.g. `hy-mt2-1.8b-q4` (also the install folder).
  final String id;

  /// File name as published and installed, e.g.
  /// `Hy-MT2-1.8B-Q4_K_M.gguf`.
  final String name;

  /// Where the file is downloaded from by default (https, pinned to a
  /// commit; see `llamaDownloadUrls` for mirrors).
  final Uri url;

  /// Exact bytes of the file, checked while downloading.
  final int size;

  /// Lower-case hex SHA-256 of the file (Hugging Face's LFS object id),
  /// checked before the file is installed.
  final String sha256;

  /// What the model is for.
  final LlamaModelRole role;

  /// The architecture as llama.cpp names it: `hunyuan-dense`, `gemma4` or
  /// `qwen3` ([families]).
  final String family;

  /// The name of the `PromptProfile` the app prompts the model with
  /// (`hunyuanMt` for Hy-MT2, `general` for the assistants;
  /// [promptProfiles]).
  final String promptProfile;

  /// The name the app shows, e.g. `Hy-MT2 1.8B`.
  final String displayName;

  /// Parameter count as the publisher states it, e.g. `1.8B`.
  final String parameters;

  /// The quantization of the weights, e.g. `Q4_K_M`.
  final String quantization;

  /// Context window (tokens) the app loads the model with.
  final int contextSize;

  /// RAM (MiB, as Android reports it) below which the model is not offered
  /// for download: it would not run well, if at all. Importing it stays
  /// possible.
  final int minRamMb;

  /// RAM (MiB) below which the model may be slow.
  final int recommendedRamMb;

  /// The languages a translation model translates (app language codes);
  /// empty for an assistant (it follows its prompts).
  final List<String> languages;

  /// SPDX identifier of the weights' licence, e.g. `Apache-2.0`.
  final String license;

  /// The licence text.
  final Uri licenseUrl;

  /// The model's home page (its publisher's repository or model card).
  final Uri sourceUrl;

  /// Recommended sampling.
  final LlamaCatalogSampling sampling;

  /// Model families the app knows (llama.cpp architectures).
  static const families = {'hunyuan-dense', 'gemma4', 'qwen3'};

  /// The `PromptProfile` names of translation_repository.
  static const promptProfiles = {
    'auto',
    'general',
    'translateGemma',
    'hunyuanMt',
  };

  /// Whether [id] is a safe model id (also a folder name):
  /// `^[a-z0-9][a-z0-9_.-]{0,47}$` without `..`.
  static bool isSafeId(String id) => _safeId.hasMatch(id) && !id.contains('..');

  static final _safeId = RegExp(r'^[a-z0-9][a-z0-9_.-]{0,47}$');
  static final _safeName = RegExp(r'^[A-Za-z0-9._-]{1,200}$');
  static final _sha256Pattern = RegExp(r'^[0-9a-f]{64}$');
  static final _quantizationPattern = RegExp(r'^[A-Za-z0-9_]{1,16}$');
  static final _licensePattern = RegExp(r'^[A-Za-z0-9.+-]{1,64}$');
  static final _languagePattern = RegExp(r'^[a-z]{2,3}(-[A-Za-z0-9]{2,8})*$');
  static final _control = RegExp(r'[\x00-\x1f\x7f]');

  static String _string(Map<String, Object?> json, String key) {
    final value = json[key];
    if (value is! String || value.trim().isEmpty) {
      throw FormatException('Missing "$key"', json);
    }
    return value;
  }

  static Uri _https(Map<String, Object?> json, String key) {
    final url = Uri.tryParse(_string(json, key));
    if (url == null ||
        !url.isScheme('https') ||
        url.host.isEmpty ||
        url.userInfo.isNotEmpty) {
      throw FormatException('"$key" must be an https URL', json[key]);
    }
    return url;
  }

  static List<String> _languages(Object? json) {
    if (json is! List<Object?>) {
      throw FormatException('Invalid languages', json);
    }
    final codes = <String>[];
    for (final code in json) {
      if (code is! String || !_languagePattern.hasMatch(code)) {
        throw FormatException('Invalid language code', code);
      }
      if (codes.contains(code)) {
        throw FormatException('Duplicate language code', code);
      }
      codes.add(code);
    }
    return List.unmodifiable(codes);
  }

  @override
  bool operator ==(Object other) =>
      other is LlamaCatalogModel &&
      other.id == id &&
      other.name == name &&
      other.url == url &&
      other.size == size &&
      other.sha256 == sha256 &&
      other.role == role &&
      other.family == family &&
      other.promptProfile == promptProfile &&
      other.displayName == displayName &&
      other.parameters == parameters &&
      other.quantization == quantization &&
      other.contextSize == contextSize &&
      other.minRamMb == minRamMb &&
      other.recommendedRamMb == recommendedRamMb &&
      _sameList(other.languages, languages) &&
      other.license == license &&
      other.licenseUrl == licenseUrl &&
      other.sourceUrl == sourceUrl &&
      other.sampling == sampling;

  @override
  int get hashCode => Object.hash(
    id,
    name,
    url,
    size,
    sha256,
    role,
    family,
    promptProfile,
    displayName,
    parameters,
    quantization,
    contextSize,
    minRamMb,
    recommendedRamMb,
    Object.hashAll(languages),
    license,
    licenseUrl,
    sourceUrl,
    sampling,
  );

  static bool _sameList(List<String> a, List<String> b) {
    if (a.length != b.length) return false;
    for (var i = 0; i < a.length; i++) {
      if (a[i] != b[i]) return false;
    }
    return true;
  }

  @override
  String toString() => 'LlamaCatalogModel($id, $name)';
}

/// The on-device models that can be downloaded (`assets/models.json`), in
/// the order the app offers them.
@immutable
final class LlamaModelCatalog {
  const new({this.models = const []});

  /// Parses `models.json`. Throws [FormatException] when it is invalid: an
  /// unknown schema, an invalid entry (see [LlamaCatalogModel.fromJson]),
  /// duplicate ids or file names. An empty `models` list is valid (the
  /// catalogue before its entries are resolved).
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
    if (entries is! List<Object?>) {
      throw const FormatException('The catalog has no model list');
    }
    final models = <LlamaCatalogModel>[];
    final ids = <String>{};
    final names = <String>{};
    for (final entry in entries) {
      if (entry is! Map<String, Object?>) {
        throw FormatException('Invalid model entry', entry);
      }
      final model = LlamaCatalogModel.fromJson(entry);
      if (!ids.add(model.id) || !names.add(model.name.toLowerCase())) {
        throw FormatException('Duplicate model', model.id);
      }
      models.add(model);
    }
    return LlamaModelCatalog(models: List.unmodifiable(models));
  }

  /// `models.json` schema this code reads.
  static const schemaVersion = 1;

  /// Asset key of the bundled catalog (see `loadBundledLlamaCatalog`).
  static const assetKey = 'packages/llama_engine/assets/models.json';

  /// Every model, in the order the app offers them.
  final List<LlamaCatalogModel> models;

  /// Whether the catalog lists no model.
  bool get isEmpty => models.isEmpty;

  /// The model with [id], if listed.
  LlamaCatalogModel? model(String id) {
    for (final model in models) {
      if (model.id == id) return model;
    }
    return null;
  }

  /// The models of [role], in catalog order.
  List<LlamaCatalogModel> ofRole(LlamaModelRole role) => [
    for (final model in models)
      if (model.role == role) model,
  ];
}
