import 'dart:async';
import 'dart:io';

import 'package:bergamot_translator/src/catalog.dart';
import 'package:bergamot_translator/src/engine/bergamot_engine.dart';
import 'package:bergamot_translator/src/engine/engine_factory.dart';
import 'package:bergamot_translator/src/language_identifier.dart';
import 'package:bergamot_translator/src/model_manager.dart';
import 'package:bergamot_translator/src/model_router.dart';
import 'package:bergamot_translator/src/native_language_identifier.dart';
import 'package:bergamot_translator/src/text_chunker.dart';
import 'package:http/http.dart' as http;
import 'package:translation_repository/translation_repository.dart';

/// `downloadLanguage(wifiOnly: true)` was called on a metered connection.
/// Nothing was downloaded.
final class MeteredConnectionException implements Exception {
  const new();

  @override
  String toString() => 'MeteredConnectionException()';
}

/// [OfflineTranslator] backed by Mozilla's Firefox Translations models and
/// the open-source Bergamot engine (no Google code).
///
/// * Models come from [catalog] (`assets/catalog.json`), are downloaded and
///   verified by [models] into the app-private [BergamotModelManager.root],
///   ~15-40 MB per direction.
/// * Every model translates to or from English. A language is downloaded
///   when both of its directions are; other pairs pivot through English
///   (e.g. es -> en -> de), which needs no English download.
/// * [translate] runs in a background isolate ([engine]) and never
///   downloads anything: missing models throw [OfflineModelMissingException]
///   with the languages to download.
/// * Long text is translated in pieces of at most [maxChunkLength]
///   characters, split at paragraph, line and sentence boundaries.
/// * [identifyLanguage] runs CLD2 from the native library ([languageId],
///   in a background isolate) and decides with [Cld2Decision]; where the
///   engine cannot run it falls back to the [LanguageIdentifier] heuristic.
///
/// [isAvailable] is true on Android (arm64-v8a, x86_64, armeabi-v7a with
/// VFPv4) and false elsewhere (web, desktop) unless overridden.
class BergamotTranslator implements OfflineTranslator {
  new({
    required this.catalog,
    required Directory root,
    required this._isMeteredConnection,
    http.Client? httpClient,
    BergamotEngine? engine,
    NativeLanguageIdentifier? languageId,
    BergamotModelManager? models,
    this._isAvailable,
    this.maxChunkLength = 2000,
  }) : assert(maxChunkLength > 0, 'maxChunkLength must be positive'),
       models =
           models ?? BergamotModelManager(root: root, httpClient: httpClient),
       engine = engine ?? createBergamotEngine(),
       languageId = languageId ?? createNativeLanguageIdentifier(),
       router = ModelRouter(catalog);

  /// Whether the native engine runs on this device (see
  /// [bergamotPlatformSupported]).
  static bool get isPlatformSupported => bergamotPlatformSupported;

  final ModelCatalog catalog;
  final BergamotModelManager models;
  final BergamotEngine engine;

  /// CLD2 in the native library (see [identifyLanguage]).
  final NativeLanguageIdentifier languageId;
  final ModelRouter router;

  /// Characters of a text that [identifyLanguage] looks at: plenty for
  /// identification, and keeps long documents cheap.
  static const identificationSampleLength = 4096;

  /// Longest piece of text sent to the engine at once.
  final int maxChunkLength;

  final Future<bool> Function() _isMeteredConnection;
  final bool? _isAvailable;
  final _progress = StreamController<ModelDownloadProgress>.broadcast();

  /// Progress of [downloadLanguage] (one event per received chunk).
  Stream<ModelDownloadProgress> get downloadProgress => _progress.stream;

  @override
  bool get isAvailable => _isAvailable ?? isPlatformSupported;

  /// Languages with models in both directions, plus English.
  @override
  Set<String> get supportedLanguages => router.languages;

  /// Languages that can only be translated from (e.g. none today) or into
  /// (`az`) are not in [supportedLanguages]; these include them.
  Set<String> get sourceLanguages => router.sourceLanguages;
  Set<String> get targetLanguages => router.targetLanguages;

  /// Languages whose models are all installed (always including English,
  /// which needs none).
  @override
  Future<Set<String>> downloadedLanguages() async {
    if (!isAvailable) return const {};
    final installed = {
      for (final model in await models.installed()) model.pair,
    };
    return {
      ModelRouter.english,
      for (final code in {...supportedLanguages, ...targetLanguages})
        if (code != ModelRouter.english &&
            router.modelsFor(code).isNotEmpty &&
            router.modelsFor(code).every((m) => installed.contains(m.pair)))
          code,
    };
  }

  /// Bytes to download for [code] (both directions; already installed
  /// models count too).
  int downloadSize(String code) =>
      router.modelsFor(code).fold(0, (sum, model) => sum + model.downloadSize);

  /// Bytes used by every installed model.
  Future<int> installedSize() => models.totalSize();

  /// Installed models whose catalog entry has a newer version (installing
  /// the catalog model replaces them).
  Future<List<CatalogModel>> outdatedModels() async => [
    for (final installed in await models.installed())
      if (catalog.model(installed.source, installed.target) case final model?
          when model.version != installed.version)
        model,
  ];

  /// Downloads both directions of [code] (English: nothing to do).
  ///
  /// With [wifiOnly] it throws [MeteredConnectionException] instead of
  /// downloading over a metered connection. Throws
  /// [OfflineLanguageUnsupportedException] for languages without models and
  /// [ModelInstallException] when a download fails or does not match its
  /// checksum.
  @override
  Future<void> downloadLanguage(String code, {bool wifiOnly = true}) async {
    _ensureAvailable();
    final needed = router.modelsFor(code);
    if (needed.isEmpty) {
      if (router.targetCode(code) == ModelRouter.english) return;
      throw OfflineLanguageUnsupportedException(code);
    }
    final missing = [
      for (final model in needed)
        if (!await models.isInstalled(model)) model,
    ];
    if (missing.isEmpty) return;
    if (wifiOnly && await _isMeteredConnection()) {
      throw const MeteredConnectionException();
    }
    for (final model in missing) {
      await models.install(model, onProgress: _progress.add);
    }
  }

  /// Deletes both directions of [code] (English: nothing to delete).
  /// Models that another downloaded language still needs (Serbo-Croatian
  /// -> English serves Croatian, Bosnian and Serbian) are kept.
  @override
  Future<void> deleteLanguage(String code) async {
    _ensureAvailable();
    final pairs = router.modelsFor(code);
    if (pairs.isEmpty) {
      if (router.targetCode(code) == ModelRouter.english) return;
      throw OfflineLanguageUnsupportedException(code);
    }
    final own = pairs.map((model) => model.pair).toSet();
    final shared = <String>{};
    for (final other in await downloadedLanguages()) {
      final needs = router.modelsFor(other).map((model) => model.pair).toSet();
      // The same language under another code (e.g. nb/no) is not "other".
      if (needs.length == own.length && needs.containsAll(own)) continue;
      shared.addAll(needs);
    }
    for (final pair in pairs) {
      if (shared.contains(pair.pair)) continue;
      final installed = await models.installedModel(pair.source, pair.target);
      if (installed != null) await engine.release(installed.paths.key);
      await models.delete(pair.source, pair.target);
    }
  }

  /// Translates [text] from [source] (`auto` or empty: identified first)
  /// into [target]. Blank text and identical languages return [text].
  /// Throws [OfflineLanguageUnsupportedException] for languages without
  /// models, [OfflineModelMissingException] (listing the languages to
  /// download) when models are not installed, and
  /// [BergamotEngineException] when the engine fails.
  @override
  Future<String> translate(
    String text, {
    required String source,
    required String target,
  }) async {
    _ensureAvailable();
    if (router.targetCode(target) == null) {
      throw OfflineLanguageUnsupportedException(target);
    }
    if (text.trim().isEmpty) return text;
    final from = _isAuto(source)
        ? await identifyLanguage(text) ??
              (throw const OfflineLanguageUnsupportedException('auto'))
        : source;
    final route =
        router.route(from, target) ??
        (throw OfflineLanguageUnsupportedException(from));
    if (route.isEmpty) return text;

    final chain = <ModelPaths>[];
    final missing = <String>[];
    for (final model in route) {
      final installed = await models.installedModel(model.source, model.target);
      if (installed != null) {
        chain.add(installed.paths);
      } else {
        final language = model.source == ModelRouter.english
            ? model.target
            : model.source;
        final reported = language == 'hbs'
            ? from
            : ModelRouter.reportedCode(language);
        if (!missing.contains(reported)) missing.add(reported);
      }
    }
    if (missing.isNotEmpty) throw OfflineModelMissingException(missing);

    final output = StringBuffer();
    for (final piece in TextChunker.split(text, maxLength: maxChunkLength)) {
      output.write(await _translatePiece(chain, piece));
    }
    return output.toString();
  }

  /// BCP-47 code of [text]'s language, or null when undetermined. The
  /// result may be a language without a model; Traditional Chinese is
  /// `zh-Hant`.
  ///
  /// Looks at the first [identificationSampleLength] characters. Where the
  /// engine runs ([isAvailable]) CLD2 identifies them in a background
  /// isolate and [Cld2Decision.choose] decides, preferring the languages
  /// this engine translates from on weak evidence, and those whose models
  /// are installed ([downloadedLanguages]) on weaker. Elsewhere (web, CPUs
  /// the engine does not support), or when the native identifier is
  /// missing or fails, the [LanguageIdentifier] heuristic answers alone.
  @override
  Future<String?> identifyLanguage(String text) async {
    if (text.trim().isEmpty) return null;
    final sample = _sample(text);
    final heuristic = LanguageIdentifier.identify(sample);
    if (!isAvailable) return heuristic;
    final Cld2Detection? detection;
    try {
      detection = await languageId.identify(sample);
    } on Object {
      return heuristic;
    }
    if (detection == null) return heuristic;
    Set<String> installed;
    try {
      installed = await downloadedLanguages();
    } on Object {
      installed = const {};
    }
    return Cld2Decision.choose(
      detection,
      heuristic: heuristic,
      preferred: sourceLanguages,
      installed: installed,
    );
  }

  /// Unloads every model and stops the translation isolate. The instance
  /// stays usable.
  @override
  Future<void> dispose() => engine.dispose();

  /// Translates one piece, keeping its leading and trailing whitespace
  /// exactly.
  Future<String> _translatePiece(List<ModelPaths> chain, String piece) async {
    final match = _padding.firstMatch(piece)!;
    final core = match.group(2)!;
    if (core.isEmpty) return piece;
    final translated = await engine.translate(chain, core);
    return '${match.group(1)}${translated.trim()}${match.group(3)}';
  }

  void _ensureAvailable() {
    if (!isAvailable) {
      throw UnsupportedError(
        'Offline translation is not available on this device',
      );
    }
  }

  /// The first [identificationSampleLength] UTF-16 code units of [text],
  /// without splitting a surrogate pair.
  static String _sample(String text) {
    if (text.length <= identificationSampleLength) return text;
    var end = identificationSampleLength;
    final last = text.codeUnitAt(end - 1);
    if (last >= 0xD800 && last <= 0xDBFF) end--;
    return text.substring(0, end);
  }

  static bool _isAuto(String code) {
    final key = code.trim().toLowerCase();
    return key.isEmpty || key == 'auto';
  }

  static final _padding = RegExp(r'^(\s*)([\s\S]*?)(\s*)$');
}
