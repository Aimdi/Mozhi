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
///   ~15-40 MB per direction; with `freeSpace` a download first checks
///   that they fit ([ModelInsufficientSpaceException]).
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
class BergamotTranslator implements DetailedOfflineTranslator {
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
    this.maxBatchLength = 6000,
    Future<int?> Function(String path)? freeSpace,
  }) : assert(maxChunkLength > 0, 'maxChunkLength must be positive'),
       assert(maxBatchLength > 0, 'maxBatchLength must be positive'),
       models =
           models ??
           BergamotModelManager(
             root: root,
             httpClient: httpClient,
             freeSpace: freeSpace,
           ),
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

  /// Longest piece of text the engine translates as one unit.
  final int maxChunkLength;

  /// Most characters of pieces sent to the engine in one native call (one
  /// batch): about Bergamot's mini-batch (1024 words), so typed text goes
  /// in one call, and a long document can still be cancelled between
  /// batches.
  final int maxBatchLength;

  /// [OfflineSentence.score] (the mean log-probability of its words) below
  /// which a sentence [OfflineSentence.isLowConfidence]. Fluent
  /// translations score about -0.1 to -0.3; text in another language than
  /// the source, garbled output and the like about -0.4 to -0.8. The
  /// scores are relative to the vocabulary the shortlist allows for the
  /// whole batch, so a bad sentence scores lower in a longer text than
  /// alone (fluent ones barely change).
  static const lowConfidenceScore = -0.4;

  /// Words a sentence needs before it can be [OfflineSentence.isLowConfidence]:
  /// the scores of one or two words ("You" -> "Du") say little.
  static const lowConfidenceMinWords = 3;

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
  ///
  /// Once [abort] completes, it stops before the next batch of pieces and
  /// throws [OfflineTranslationCancelledException]; a batch waiting for the
  /// engine (e.g. behind another request) is dropped.
  @override
  Future<String> translate(
    String text, {
    required String source,
    required String target,
    Future<void>? abort,
  }) async => (await _translate(
    text,
    source: source,
    target: target,
    abort: _Abort(abort),
    details: false,
  )).text;

  /// [translate] with the sentences of the result: their source and target
  /// ranges, word alignment and quality scores, and
  /// [OfflineSentence.isLowConfidence] for sentences of at least
  /// [lowConfidenceMinWords] words whose score is below
  /// [lowConfidenceScore]. Needs an engine with batches
  /// ([BergamotBatchEngine], the default); with another one the result has
  /// no sentences.
  @override
  Future<OfflineTranslation> translateDetailed(
    String text, {
    required String source,
    required String target,
    Future<void>? abort,
  }) => _translate(
    text,
    source: source,
    target: target,
    abort: _Abort(abort),
    details: true,
  );

  /// Loads the installed models of [source] -> [target] in the engine
  /// isolate, so that the next translation starts at once (see
  /// [DetailedOfflineTranslator.preload]). False for an `auto` source,
  /// missing models, an unsupported pair or an engine without warm-up.
  @override
  Future<bool> preload({required String source, required String target}) async {
    final engine = this.engine;
    if (!isAvailable || _isAuto(source) || engine is! BergamotBatchEngine) {
      return false;
    }
    try {
      final chain = await _chainFor(source, target);
      if (chain == null) return false;
      await engine.preload(chain);
      return true;
    } on Object {
      return false;
    }
  }

  /// Unloads every model but those of the most recent translation (call on
  /// memory pressure); they load again when needed. Does nothing for an
  /// engine without [BergamotBatchEngine.trim].
  Future<void> trimMemory() async {
    final engine = this.engine;
    if (engine is BergamotBatchEngine) await engine.trim();
  }

  Future<OfflineTranslation> _translate(
    String text, {
    required String source,
    required String target,
    required _Abort abort,
    required bool details,
  }) async {
    _ensureAvailable();
    if (router.targetCode(target) == null) {
      throw OfflineLanguageUnsupportedException(target);
    }
    if (text.trim().isEmpty) return OfflineTranslation(text: text);
    final from = _isAuto(source)
        ? await identifyLanguage(text) ??
              (throw const OfflineLanguageUnsupportedException('auto'))
        : source;
    abort.check();
    final chain = await _chainFor(from, target);
    if (chain == null) return OfflineTranslation(text: text);
    return await _translatePieces(chain, text, abort: abort, details: details);
  }

  /// The installed models from [from] to [target] (one, or two through
  /// English), or null when they are the same language. Throws
  /// [OfflineLanguageUnsupportedException] or
  /// [OfflineModelMissingException].
  Future<List<ModelPaths>?> _chainFor(String from, String target) async {
    final route =
        router.route(from, target) ??
        (throw OfflineLanguageUnsupportedException(from));
    if (route.isEmpty) return null;

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
    return chain;
  }

  /// Translates [text] in pieces of at most [maxChunkLength] characters,
  /// sent to the engine in batches of up to [maxBatchLength] characters (one
  /// native call each, so the engine batches their sentences), checking
  /// [abort] before each batch. Every piece keeps its leading and trailing
  /// whitespace exactly; sentence offsets are moved to the whole text.
  Future<OfflineTranslation> _translatePieces(
    List<ModelPaths> chain,
    String text, {
    required _Abort abort,
    required bool details,
  }) async {
    final pieces = [
      for (final piece in TextChunker.split(text, maxLength: maxChunkLength))
        _Piece(piece),
    ];
    final engine = this.engine;
    final translated = List<OfflineTranslation?>.filled(pieces.length, null);
    if (engine is BergamotBatchEngine) {
      for (final batch in _batches(pieces)) {
        abort.check();
        final results = await engine.translateBatch(
          chain,
          [for (final index in batch) pieces[index].core],
          details: details,
          abort: abort.future,
        );
        for (final (i, index) in batch.indexed) {
          translated[index] = results[i];
        }
      }
    } else {
      for (final (index, piece) in pieces.indexed) {
        if (piece.core.isEmpty) continue;
        abort.check();
        translated[index] = OfflineTranslation(
          text: await engine.translate(chain, piece.core),
        );
      }
    }
    abort.check();

    final output = StringBuffer();
    final sentences = <OfflineSentence>[];
    var sourceOffset = 0;
    for (final (index, piece) in pieces.indexed) {
      final result = translated[index];
      if (result == null) {
        output.write(piece.text);
      } else {
        final trimmed = result.text.trim();
        final cut = result.text.length - result.text.trimLeft().length;
        final targetOffset = output.length + piece.lead.length - cut;
        output
          ..write(piece.lead)
          ..write(trimmed)
          ..write(piece.trail);
        for (final sentence in result.sentences) {
          sentences.add(
            _judged(
              sentence.shift(
                source: sourceOffset + piece.lead.length,
                target: targetOffset,
              ),
            ),
          );
        }
      }
      sourceOffset += piece.text.length;
    }
    return OfflineTranslation(text: output.toString(), sentences: sentences);
  }

  /// The indexes of the [pieces] with text, grouped into batches of at
  /// most [maxBatchLength] characters (a longer piece is a batch alone).
  List<List<int>> _batches(List<_Piece> pieces) {
    final batches = <List<int>>[];
    var batch = <int>[];
    var length = 0;
    for (final (index, piece) in pieces.indexed) {
      if (piece.core.isEmpty) continue;
      if (batch.isNotEmpty && length + piece.core.length > maxBatchLength) {
        batches.add(batch);
        batch = [];
        length = 0;
      }
      batch.add(index);
      length += piece.core.length;
    }
    if (batch.isNotEmpty) batches.add(batch);
    return batches;
  }

  /// [sentence] with [OfflineSentence.isLowConfidence] decided.
  static OfflineSentence _judged(OfflineSentence sentence) {
    final score = sentence.score;
    return sentence.withLowConfidence(
      value:
          score != null &&
          score < lowConfidenceScore &&
          sentence.words.length >= lowConfidenceMinWords,
    );
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
}

/// One piece of a text: its [core] without the whitespace around it.
final class _Piece {
  new(String text) : this._split(text, _padding.firstMatch(text)!);

  new _split(this.text, RegExpMatch match)
    : lead = match.group(1)!,
      core = match.group(2)!,
      trail = match.group(3)!;

  final String text;
  final String lead;
  final String core;
  final String trail;

  static final _padding = RegExp(r'^(\s*)([\s\S]*?)(\s*)$');
}

/// Whether a request's `abort` future has completed.
final class _Abort {
  new(this.future) {
    if (future case final abort?) {
      unawaited(
        abort.then((_) => _done = true, onError: (Object _) => _done = true),
      );
    }
  }

  final Future<void>? future;
  var _done = false;

  /// Throws [OfflineTranslationCancelledException] once aborted.
  void check() {
    if (_done) throw const OfflineTranslationCancelledException();
  }
}
