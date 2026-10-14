import 'dart:async';
import 'dart:typed_data';

import 'package:collection/collection.dart';
import 'package:llm_api/llm_api.dart';
import 'package:mozhi_api/mozhi_api.dart';
import 'package:mt_api/mt_api.dart';
import 'package:translation_repository/src/cache/translation_cache.dart';
import 'package:translation_repository/src/chunking/chunked_translation.dart';
import 'package:translation_repository/src/chunking/paragraph_chunker.dart';
import 'package:translation_repository/src/language_catalog.dart';
import 'package:translation_repository/src/language_matcher.dart';
import 'package:translation_repository/src/models/models.dart';
import 'package:translation_repository/src/offline/offline_translator.dart';
import 'package:translation_repository/src/prompts/mt_prompts.dart';
import 'package:translation_repository/src/prompts/response_parsers.dart';
import 'package:translation_repository/src/prompts/translation_prompts.dart';
import 'package:translation_repository/src/repository/ai_translation_stream.dart';
import 'package:translation_repository/src/repository/llm_pool.dart';
import 'package:translation_repository/src/repository/mappers.dart';
import 'package:translation_repository/src/repository/mozhi_pool.dart';
import 'package:translation_repository/src/repository/mt_engines.dart';
import 'package:translation_repository/src/repository/offline_engine.dart';
import 'package:translation_repository/src/repository/repository_exceptions.dart';

typedef MozhiClientFactory = MozhiApiClient Function(Uri baseUrl);
typedef LlmClientFactory = LlmClient Function(LlmEndpoint endpoint);

/// Creates the DeepL client of a [MtService.deepl] provider.
typedef DeeplClientFactory = DeeplClient Function(AiProviderConfig config);

/// Creates the LibreTranslate client of a [MtService.libreTranslate]
/// provider.
typedef LibreTranslateClientFactory = LibreTranslateClient Function(
  AiProviderConfig config,
);

/// The single entry point the app uses for anything translation related.
///
/// Configuration is pushed by the app whenever settings change
/// ([updateConfiguration]). Mozhi requests go to the first reachable
/// instance in [instances] order: on a failure another instance might not
/// repeat (network errors, timeouts, 3xx/4xx from a proxy, 429, 5xx that
/// are not Mozhi input errors) the next instance is tried and, on success,
/// becomes the preferred one ([activeInstance]) until the instance order
/// changes or [resetActiveInstance] is called. Requests that carry the
/// user's text or image are not re-sent after a timeout, because the slow
/// instance may already have received them.
///
/// Language lists and engine lists are cached in memory per instance+engine
/// (keyed by the instance that answered; cleared by [updateConfiguration]
/// when instances change, or `refresh: true`). Final translations are
/// cached in a [TranslationCache] ([clearCache]); a provider's entries are
/// dropped whenever its configuration changes.
class TranslationRepository {
  /// [mozhiClientFactory] / [llmClientFactory] / [deeplClientFactory] /
  /// [libreTranslateClientFactory] create the HTTP clients (defaults:
  /// `MozhiApiClient(baseUrl: ...)`, `LlmClient(endpoint)`,
  /// `DeeplClient(authKey: apiKey, baseUrl: ...)`,
  /// `LibreTranslateClient(baseUrl: ..., apiKey: ...)`). Clients are cached
  /// per Mozhi instance URL and per provider connection settings.
  ///
  /// [offline] enables the on-device engine ([TranslationEngine.offline])
  /// when it [OfflineTranslator.isAvailable]; it is also used to identify
  /// the source language privately where a detection is needed.
  ///
  /// [cache] stores final results (default: a [TranslationCache] with its
  /// default size and lifetime; pass `TranslationCache(maxEntries: 0)` to
  /// disable caching).
  ///
  /// `snapshotInterval` throttles intermediate AI streaming snapshots.
  ///
  /// AI inputs longer than `aiChunkThreshold` characters
  /// (`localAiChunkThreshold` for providers on this machine or the local
  /// network, whose models usually have small context windows) are
  /// translated in parts of at most that size (see [translate]); both must
  /// be at least 1 ([RangeError] otherwise).
  ///
  /// `detectionHintTimeout` is how long the final result of a short
  /// auto-detected AI translation may wait for the second language
  /// detection (see [translate]).
  new({
    MozhiClientFactory? mozhiClientFactory,
    LlmClientFactory? llmClientFactory,
    DeeplClientFactory? deeplClientFactory,
    LibreTranslateClientFactory? libreTranslateClientFactory,
    OfflineTranslator? offline,
    TranslationCache? cache,
    this._snapshotInterval = const Duration(milliseconds: 50),
    this._aiChunkThreshold = defaultAiChunkThreshold,
    this._localAiChunkThreshold = defaultLocalAiChunkThreshold,
    this._detectionHintTimeout = defaultDetectionHintTimeout,
  }) : _mozhi = MozhiPool(mozhiClientFactory ?? _defaultMozhiClient),
       _llm = LlmPool(llmClientFactory ?? _defaultLlmClient),
       _mt = MtEngines(
         deepl: deeplClientFactory,
         libre: libreTranslateClientFactory,
       ),
       _offline = offline == null ? null : OfflineEngine(offline),
       _cache = cache ?? TranslationCache() {
    if (_aiChunkThreshold < 1) {
      throw RangeError.value(_aiChunkThreshold, 'aiChunkThreshold');
    }
    if (_localAiChunkThreshold < 1) {
      throw RangeError.value(_localAiChunkThreshold, 'localAiChunkThreshold');
    }
  }

  /// Default `aiChunkThreshold`: AI inputs of cloud providers longer than
  /// this many characters are translated in parts.
  static const defaultAiChunkThreshold = 6000;

  /// Default `localAiChunkThreshold`: AI inputs of local providers longer
  /// than this many characters are translated in parts.
  static const defaultLocalAiChunkThreshold = 2500;

  /// Default `detectionHintTimeout`.
  static const defaultDetectionHintTimeout = Duration(seconds: 2);

  static MozhiApiClient _defaultMozhiClient(Uri baseUrl) =>
      MozhiApiClient(baseUrl: baseUrl);

  static LlmClient _defaultLlmClient(LlmEndpoint endpoint) =>
      LlmClient(endpoint);

  final MozhiPool _mozhi;
  final LlmPool _llm;
  final MtEngines _mt;
  final OfflineEngine? _offline;
  final TranslationCache _cache;
  final Duration _snapshotInterval;
  final int _aiChunkThreshold;
  final int _localAiChunkThreshold;
  final Duration _detectionHintTimeout;
  List<AiProviderConfig> _providers = const [];

  /// Keyed by the URL of the instance that answered (+ engine and direction
  /// for languages).
  final Map<String, Future<List<TranslationEngine>>> _engines = {};
  final Map<String, Future<List<Language>>> _languages = {};

  static const _jsonRetryInstruction =
      'Your previous reply could not be parsed. Reply again with ONLY the '
      'single valid JSON object in the requested schema: no prose, no '
      'Markdown, no code fences.';

  void updateConfiguration({
    required List<MozhiInstance> instances,
    required List<AiProviderConfig> providers,
  }) {
    if (_mozhi.update(instances)) _clearMozhiCaches();
    final current = {for (final provider in providers) provider.id: provider};
    for (final previous in _providers) {
      if (current[previous.id] != previous) _invalidateProvider(previous.id);
    }
    _providers = List.unmodifiable(providers);
    _llm.update(providers);
    _mt.update(providers);
  }

  /// Drops cached translations of the engines of provider [id].
  void _invalidateProvider(String id) {
    _cache
      ..invalidateEngine('ai:$id')
      ..invalidateEngine('mt:$id');
  }

  List<MozhiInstance> get instances => _mozhi.instances;
  List<AiProviderConfig> get providers => _providers;

  /// Instance currently preferred for Mozhi calls (null when none).
  MozhiInstance? get activeInstance => _mozhi.active;

  /// Forgets the instance a failover switched to, so the next Mozhi request
  /// starts at the first configured instance again (e.g. after the user
  /// chose that instance explicitly).
  void resetActiveInstance() => _mozhi.resetPreferred();

  /// Whether the on-device engine is available (an [OfflineTranslator] was
  /// injected and is available on this platform).
  bool get hasOfflineEngine => _offline?.isAvailable ?? false;

  /// Removes every cached translation.
  void clearCache() => _cache.clear();

  /// Engines: Mozhi engines advertised by the active instance (via
  /// `/api/engines`, `subtitle` = instance display name, i.e. its label or
  /// host), then the enabled providers in configuration order (AI providers:
  /// `ai:<id>`, `subtitle` = model, `promptProfile` resolved; machine
  /// translation services: `mt:<id>`, `subtitle` = service or host,
  /// `mtService`), then [TranslationEngine.offline] when [hasOfflineEngine].
  /// If no instance is reachable, returns only the other engines (and does
  /// not throw) unless there are none, in which case the last error is
  /// thrown.
  ///
  /// `refresh: true` reloads the Mozhi engine and language lists and the
  /// services' language lists, and starts at the first instance again.
  Future<List<TranslationEngine>> getEngines({bool refresh = false}) async {
    if (refresh) {
      _clearMozhiCaches();
      _mozhi.resetPreferred();
      _mt.clearLanguages();
    }
    final others = [
      for (final provider in _providers)
        if (provider.enabled) _engineFor(provider),
      if (hasOfflineEngine) TranslationEngine.offline(),
    ];
    if (_mozhi.instances.isEmpty) return others;
    try {
      return [...await _loadMozhiEngines(), ...others];
    } on Object {
      if (others.isEmpty) rethrow;
      return others;
    }
  }

  static TranslationEngine _engineFor(AiProviderConfig provider) =>
      provider.isMtService
      ? TranslationEngine(
          id: 'mt:${provider.id}',
          kind: EngineKind.mt,
          name: provider.name,
          subtitle: _mtSubtitle(provider),
          providerId: provider.id,
          isLocal: provider.isLocal,
          mtService: provider.service,
        )
      : TranslationEngine(
          id: 'ai:${provider.id}',
          kind: EngineKind.ai,
          name: provider.name,
          subtitle: provider.model,
          providerId: provider.id,
          isLocal: provider.isLocal,
          promptProfile: provider.resolvedPromptProfile,
        );

  static String _mtSubtitle(AiProviderConfig provider) {
    final url = provider.baseUrl.trim();
    final host = url.isEmpty
        ? ''
        : Uri.tryParse(url.contains('://') ? url : 'https://$url')?.host ?? '';
    if (host.isNotEmpty) return host;
    return provider.service == MtService.deepl ? 'DeepL API' : 'LibreTranslate';
  }

  Future<List<TranslationEngine>> _loadMozhiEngines() =>
      _cachedMozhi(_engines, '', (client, instance) async {
        final engines = await client.getEngines();
        return List<TranslationEngine>.unmodifiable([
          for (final MapEntry(key: id, value: name) in engines.entries)
            TranslationEngine(
              id: 'mozhi:$id',
              kind: EngineKind.mozhi,
              name: name.isEmpty ? id : name,
              subtitle: instance.displayName,
              mozhiEngine: id,
            ),
        ]);
      });

  void _clearMozhiCaches() {
    _engines.clear();
    _languages.clear();
  }

  /// Returns the cached future for [suffix] on the active instance, or
  /// loads it with failover. The entry is stored under the instance that
  /// actually answered, so a later failover back to the first instance does
  /// not serve the other instance's list. Failed loads are evicted so the
  /// next call retries.
  Future<T> _cachedMozhi<T>(
    Map<String, Future<T>> cache,
    String suffix,
    Future<T> Function(MozhiApiClient client, MozhiInstance instance) load,
  ) {
    String keyFor(String url) => suffix.isEmpty ? url : '$url|$suffix';
    final key = keyFor(_mozhi.active?.url ?? '');
    final cached = cache[key];
    if (cached != null) return cached;
    late final Future<T> future;
    Future<T> fetch() async {
      try {
        final (url, value) = await _mozhi.run(
          (client, instance) async =>
              (instance.url, await load(client, instance)),
        );
        final actual = keyFor(url);
        if (actual != key && identical(cache[key], future)) {
          cache
            ..removeWhere((entry, _) => entry == key)
            ..[actual] = future;
        }
        return value;
      } on Object {
        cache.removeWhere((_, value) => identical(value, future));
        rethrow;
      }
    }

    future = fetch();
    cache[key] = future;
    return future;
  }

  /// Mozhi: `/api/source_languages` mapped to [Language] (id `auto` ->
  /// [Language.auto] first, names from the engine, `nativeName` from
  /// `LanguageCatalog` when known). AI: [Language.auto] + catalogue.
  /// Offline: [Language.auto] + the backend's languages. Machine
  /// translation services: [Language.auto] + the service's list (cached).
  Future<List<Language>> getSourceLanguages(TranslationEngine engine) =>
      switch (engine.kind) {
        EngineKind.ai => Future.sync(
          () => [Language.auto, ...LanguageCatalog.all],
        ),
        EngineKind.mozhi => _mozhiLanguages(engine, source: true),
        EngineKind.offline => Future.sync(
          () => _offlineFor(engine).sourceLanguages,
        ),
        EngineKind.mt => Future.sync(
          () => _mt.sourceLanguages(_mtProviderFor(engine)),
        ),
      };

  /// Mozhi: `/api/target_languages` (for DeepL, regional ids Mozhi cannot
  /// translate into are mapped to their base language, and `zh-hant` is
  /// dropped). AI: catalogue. Offline: the backend's languages. Machine
  /// translation services: the service's list (cached).
  Future<List<Language>> getTargetLanguages(TranslationEngine engine) =>
      switch (engine.kind) {
        EngineKind.ai => Future.sync(() => LanguageCatalog.all),
        EngineKind.mozhi => _mozhiLanguages(engine, source: false),
        EngineKind.offline => Future.sync(() => _offlineFor(engine).languages),
        EngineKind.mt => Future.sync(
          () => _mt.targetLanguages(_mtProviderFor(engine)),
        ),
      };

  Future<List<Language>> _mozhiLanguages(
    TranslationEngine engine, {
    required bool source,
  }) {
    final id = mozhiEngineId(engine);
    return _cachedMozhi(_languages, '$id|${source ? 'source' : 'target'}', (
      client,
      _,
    ) async {
      final languages = source
          ? await client.getSourceLanguages(id)
          : await client.getTargetLanguages(id);
      final fixed = !source && id.toLowerCase() == 'deepl'
          ? fixMozhiDeeplTargets(languages)
          : languages;
      return List<Language>.unmodifiable(mapMozhiLanguages(fixed));
    });
  }

  /// Mozhi, offline and machine translation engines: one complete result.
  /// Mozhi results carry transliterations, word choices and synonyms; an
  /// empty translation of non-empty text is a retryable
  /// `MozhiApiException` (status 502, "Google returned an empty
  /// translation."). AI: streams growing snapshots (`isComplete: false`)
  /// and a final `isComplete: true` result; the `[[lang:xx]]` marker is
  /// parsed into `detectedSource` and never shown; `<think>` content never
  /// appears; text is passed through `ResponseParsers.cleanTranslation` on
  /// completion. Empty/whitespace input emits nothing and completes.
  /// `detectedSource` is normalised and only set for an auto source.
  ///
  /// Translation-specialised AI models ([TranslationEngine.usesMtProfile])
  /// get `MtPrompts` (no options, no marker, the model card's sampling
  /// unless the provider sets a temperature) and need a source language:
  /// for an auto source it is identified on the device when possible, else
  /// (for non-local engines) with Mozhi, else
  /// [SourceLanguageRequiredException] is emitted.
  ///
  /// Partial AI snapshots carry `detectedSource` as soon as the model's
  /// `[[lang:xx]]` marker has arrived (with empty text if nothing follows it
  /// yet), so a caller can stop early when the source is the target.
  ///
  /// Long AI inputs (more than `aiChunkThreshold` characters, or
  /// `localAiChunkThreshold` for local providers; see the constructor) are
  /// translated in parts: split at paragraph boundaries (overlong paragraphs
  /// at sentence ends, never inside fenced code blocks), two parts at a
  /// time, each part after the first with the end of the previous one as
  /// context. With an auto source the first part is translated alone and
  /// its detected language is used for the others. Snapshots combine the
  /// parts in order, joined with the original whitespace between them, and
  /// carry the first part's `detectedSource`; the result is complete once
  /// every part is. An error in one part cancels the others and is emitted.
  ///
  /// Short input (at most 3 words) with an auto source on a cloud AI engine
  /// with [TranslationEngine.supportsExtras] is also checked with a second
  /// detection ([detectLanguage]) in parallel. When it is unsure, names
  /// other likely languages or disagrees with the translation's
  /// `detectedSource`, the final result has `detectionUncertain` and up to
  /// 3 `detectedAlternatives` (the request's `recentSourceLanguages` first).
  /// The check never fails the translation (its errors are ignored); when
  /// it is still running as the translation finishes, the finished text is
  /// emitted as a partial snapshot right away and the final result waits
  /// for the check at most `detectionHintTimeout` (then without the hint).
  ///
  /// Final results are served from and stored in the cache (results served
  /// from it have `fromCache: true`; long inputs are cached as a whole,
  /// never per part); `refresh: true` skips the lookup (e.g. "Regenerate").
  ///
  /// Errors are forwarded as-is (`MozhiApiException`, `LlmApiException`,
  /// `LlmRefusalException`, `MtApiException`,
  /// `OfflineModelMissingException`, `OfflineLanguageUnsupportedException`,
  /// [SourceLanguageRequiredException]). Cancelling the subscription
  /// cancels the underlying HTTP request (AI, DeepL and LibreTranslate).
  ///
  /// A custom language on an engine that cannot take one, or an engine
  /// whose provider is not configured, is reported as an [ArgumentError]
  /// stream error.
  Stream<TranslationResult> translate(
    TranslationEngine engine,
    TranslationRequest request, {
    bool refresh = false,
  }) => _translate(engine, request, refresh: refresh, detectionHint: true);

  /// [translate]; [detectionHint] enables the second detection of short
  /// input (compare mode does without it).
  Stream<TranslationResult> _translate(
    TranslationEngine engine,
    TranslationRequest request, {
    required bool refresh,
    required bool detectionHint,
  }) {
    if (request.text.trim().isEmpty) return const Stream.empty();
    final safe = _sanitizeRequest(request);
    if (safe == null) return Stream.error(_emptyCustomLanguage(request));
    if (refresh) _cache.remove(engine, safe);
    return _cache.cachedTranslate(engine, safe, () {
      final translation = _translateUncached(engine, safe);
      return detectionHint && _wantsDetectionHint(engine, safe)
          ? _withDetectionHint(engine, safe, translation)
          : translation;
    });
  }

  /// Security W4: free-form (custom) language names end up in the system
  /// prompt and may come from a link. They are passed through
  /// [TranslationPrompts.sanitizeCustomLanguage] (one line, no quotes or
  /// angle brackets, at most 60 characters) before anything else sees them,
  /// so results and cache entries carry the sanitised name. Null when a
  /// custom name is empty after sanitising.
  static TranslationRequest? _sanitizeRequest(TranslationRequest request) {
    final source = _sanitizeLanguage(request.source);
    final target = _sanitizeLanguage(request.target);
    if (source == null || target == null) return null;
    if (identical(source, request.source) &&
        identical(target, request.target)) {
      return request;
    }
    return request.copyWith(source: source, target: target);
  }

  static Language? _sanitizeLanguage(Language language) {
    if (!language.isCustom) return language;
    final name = TranslationPrompts.sanitizeCustomLanguage(language.code);
    if (name.isEmpty) return null;
    return name == language.code && name == language.name
        ? language
        : Language.custom(name);
  }

  static ArgumentError _emptyCustomLanguage(TranslationRequest request) {
    final empty =
        request.source.isCustom && _sanitizeLanguage(request.source) == null
        ? request.source
        : request.target;
    return ArgumentError.value(
      empty.code,
      empty == request.source ? 'source' : 'target',
      'Custom language name is empty',
    );
  }

  Stream<TranslationResult> _translateUncached(
    TranslationEngine engine,
    TranslationRequest request,
  ) => switch (engine.kind) {
    EngineKind.mozhi => Stream.fromFuture(_translateMozhi(engine, request)),
    EngineKind.ai => _translateAi(engine, request),
    EngineKind.offline => Stream.fromFuture(
      Future.sync(() => _offlineFor(engine).translate(engine, request)),
    ),
    EngineKind.mt => _abortable(
      (abort) =>
          _mt.translate(engine, _mtProviderFor(engine), request, abort: abort),
    ),
  };

  /// A single-result stream whose cancellation completes the abort trigger
  /// passed to [run].
  static Stream<T> _abortable<T>(Future<T> Function(Future<void> abort) run) {
    final abort = Completer<void>();
    late final StreamController<T> controller;
    controller = StreamController<T>(
      onListen: () {
        Future.sync(() => run(abort.future))
            .then(
              (value) {
                if (controller.isClosed) return;
                controller.add(value);
                unawaited(controller.close());
              },
              onError: (Object error, StackTrace stackTrace) {
                if (controller.isClosed) return;
                controller.addError(error, stackTrace);
                unawaited(controller.close());
              },
            )
            .ignore();
      },
      onCancel: () {
        if (!abort.isCompleted) abort.complete();
      },
    );
    return controller.stream;
  }

  Future<TranslationResult> _translateMozhi(
    TranslationEngine engine,
    TranslationRequest request,
  ) async {
    _checkMozhiLanguages(request.source, request.target);
    final id = mozhiEngineId(engine);
    final stopwatch = Stopwatch()..start();
    final translation = await _mozhi.run((client, _) async {
      final result = await client.translate(
        engine: id,
        from: request.source.code,
        to: mozhiTargetCode(id, request.target.code),
        text: request.text,
      );
      if (result.translatedText.trim().isEmpty) {
        // DeepL (DeepLX) reports upstream failures as 200 with an empty
        // text (mozhi-contract G2); DeepLX limits are per instance.
        throw MozhiApiException(
          '${engine.name} returned an empty translation.',
          statusCode: 502,
        );
      }
      return result;
    }, failOverOnTimeout: false);
    return mapMozhiTranslation(
      engine,
      request,
      translation,
      elapsed: stopwatch.elapsed,
    );
  }

  Stream<TranslationResult> _translateAi(
    TranslationEngine engine,
    TranslationRequest request,
  ) {
    final config = _configFor(engine, 'ai:');
    if (config == null || config.isMtService) {
      return Stream.error(
        ArgumentError.value(engine.id, 'engine', 'Unknown AI provider'),
      );
    }
    final profile = config.resolvedPromptProfile;
    if (profile.isTranslationOnly) {
      return _translateWithMtProfile(engine, config, profile, request);
    }
    return _inChunks(
      engine,
      config,
      request,
      (chunk) => aiTranslationStream(
        open: () => _llm
            .clientFor(config)
            .streamChat(
              _llmRequest(config, TranslationPrompts.translate(chunk)),
            ),
        engine: engine,
        request: chunk,
        snapshotInterval: _snapshotInterval,
      ),
    );
  }

  /// [translate] applied to [request], or to the parts of its text when it
  /// is longer than the chunk threshold of [config] (see the constructor).
  Stream<TranslationResult> _inChunks(
    TranslationEngine engine,
    AiProviderConfig config,
    TranslationRequest request,
    Stream<TranslationResult> Function(TranslationRequest chunk) translate,
  ) {
    final limit = engine.isLocal || config.isLocal
        ? _localAiChunkThreshold
        : _aiChunkThreshold;
    if (request.text.length <= limit) return translate(request);
    final chunks = ParagraphChunker.split(request.text, maxChars: limit);
    if (chunks.length < 2) return translate(request);
    return chunkedTranslation(
      engine: engine,
      request: request,
      chunks: chunks,
      translate: translate,
      languageFor: _languageFor,
    );
  }

  Stream<TranslationResult> _translateWithMtProfile(
    TranslationEngine engine,
    AiProviderConfig config,
    PromptProfile profile,
    TranslationRequest request,
  ) async* {
    if (request.source.isCustom || request.target.isCustom) {
      final custom = request.source.isCustom ? request.source : request.target;
      throw ArgumentError.value(
        custom.code,
        request.source.isCustom ? 'source' : 'target',
        '${engine.name} only translates between real languages',
      );
    }
    String? detected;
    var explicit = request;
    if (request.source.isAuto) {
      detected = await _detectSource(
        engine,
        request.text,
        isLocal: engine.isLocal || config.isLocal,
      );
      explicit = request.copyWith(source: _languageFor(detected));
    }
    if (LanguageMatcher.normalize(explicit.source.code) ==
        LanguageMatcher.normalize(explicit.target.code)) {
      // Nothing to translate; do not spend a generation on an echo.
      yield TranslationResult(
        engineId: engine.id,
        engineName: engine.name,
        text: request.text,
        detectedSource: detected,
        elapsed: Duration.zero,
      );
      return;
    }
    final sampling = MtPrompts.sampling(profile);
    yield* _inChunks(
      engine,
      config,
      explicit,
      (chunk) => aiTranslationStream(
        open: () => _llm
            .clientFor(config)
            .streamChat(
              _llmRequest(
                config,
                MtPrompts.translate(profile, chunk),
                defaultTemperature: sampling.temperature,
              ),
            ),
        engine: engine,
        request: chunk,
        snapshotInterval: _snapshotInterval,
        parseMarker: false,
        detectedSource: detected,
      ),
    );
  }

  static Language _languageFor(String code) =>
      LanguageCatalog.byCode(code) ??
      Language(code: code, name: LanguageCatalog.nameOf(code));

  /// The language of [text] for an engine that needs an explicit source:
  /// on-device identification first (private), then Mozhi google unless
  /// the engine [isLocal] (the user keeps that text off the network).
  Future<String> _detectSource(
    TranslationEngine engine,
    String text, {
    required bool isLocal,
  }) async {
    Object? failure;
    final offline = _offline;
    if (offline != null && offline.isAvailable) {
      try {
        final code = normalizeDetected(
          await offline.translator.identifyLanguage(text),
        );
        if (code != null) return code;
      } on Object catch (error) {
        failure = error;
      }
    }
    if (!isLocal && _mozhi.instances.isNotEmpty) {
      try {
        return (await _detectWithMozhi(text)).code;
      } on Object catch (error) {
        failure = error;
      }
    }
    throw SourceLanguageRequiredException(engineId: engine.id, cause: failure);
  }

  /// Most words of input that gets a second language detection.
  static const _hintMaxWords = 3;

  /// Most characters of such input (scripts without spaces).
  static const _hintMaxChars = 64;

  /// Whether [request] (sanitised) gets a second language detection: short
  /// text with an auto source on a cloud AI engine that can run the
  /// detection prompt. Local models usually serve one request at a time, so
  /// a second one would delay the translation.
  bool _wantsDetectionHint(
    TranslationEngine engine,
    TranslationRequest request,
  ) {
    if (!request.source.isAuto || !engine.supportsExtras || engine.isLocal) {
      return false;
    }
    final config = _configFor(engine, 'ai:');
    if (config == null ||
        config.isMtService ||
        config.isLocal ||
        config.resolvedPromptProfile.isTranslationOnly) {
      return false;
    }
    final text = request.text.trim();
    return text.length <= _hintMaxChars &&
        text.split(RegExp(r'\s+')).length <= _hintMaxWords;
  }

  /// Forwards [translation] while [detectLanguage] runs on the side, and
  /// adds its verdict to the final result (see [translate]).
  Stream<TranslationResult> _withDetectionHint(
    TranslationEngine engine,
    TranslationRequest request,
    Stream<TranslationResult> translation,
  ) {
    late final StreamController<TranslationResult> controller;
    StreamSubscription<TranslationResult>? subscription;
    DetectedLanguage? detection;
    var detecting = true;
    var translated = false;
    TranslationResult? held;
    TranslationResult? lastPartial;
    Timer? timer;

    void release() {
      timer?.cancel();
      timer = null;
      final result = held;
      held = null;
      if (result == null || controller.isClosed) return;
      controller.add(_withDetectionVerdict(result, detection, request));
      if (translated) unawaited(controller.close());
    }

    void onResult(TranslationResult result) {
      if (!result.isComplete) {
        lastPartial = result;
        controller.add(result);
        return;
      }
      release();
      if (!detecting) {
        controller.add(_withDetectionVerdict(result, detection, request));
        return;
      }
      // Show the finished text now; completion waits for the detection.
      final partial = result.copyWith(isComplete: false);
      if (lastPartial?.text != partial.text ||
          lastPartial?.detectedSource != partial.detectedSource) {
        controller.add(partial);
      }
      held = result;
      timer = Timer(_detectionHintTimeout, release);
    }

    controller = StreamController<TranslationResult>(
      onListen: () {
        subscription = translation.listen(
          onResult,
          onError: controller.addError,
          onDone: () {
            translated = true;
            if (held == null) unawaited(controller.close());
          },
        );
        // Started after the translation, which it must never hold up.
        unawaited(
          detectLanguage(request.text, engine: engine)
              .then<void>((value) {
                detection = value;
              }, onError: (Object _) {})
              .whenComplete(() {
                detecting = false;
                release();
              }),
        );
      },
      onPause: () => subscription?.pause(),
      onResume: () => subscription?.resume(),
      onCancel: () {
        timer?.cancel();
        held = null;
        return subscription?.cancel();
      },
    );
    return controller.stream;
  }

  /// [result] marked as uncertain when [detection] is unsure, names other
  /// likely languages or disagrees with `result.detectedSource`.
  static TranslationResult _withDetectionVerdict(
    TranslationResult result,
    DetectedLanguage? detection,
    TranslationRequest request,
  ) {
    if (detection == null) return result;
    final shown = result.detectedSource;
    final detected = normalizeDetected(detection.code);
    final disagrees =
        shown != null && detected != null && !_sameLanguage(detected, shown);
    final candidates = <String>[];
    void add(String code) {
      final normalized = normalizeDetected(code);
      if (normalized == null ||
          (shown != null && _sameLanguage(normalized, shown)) ||
          candidates.any((c) => _sameLanguage(c, normalized))) {
        return;
      }
      candidates.add(normalized);
    }

    detection.alternatives.forEach(add);
    final hasAlternatives = candidates.isNotEmpty;
    if (!detection.isUncertain && !disagrees && !hasAlternatives) {
      return result;
    }
    if (shown == null || disagrees) {
      candidates.clear();
      add(detection.code);
      detection.alternatives.forEach(add);
    }
    final recent = [
      for (final code in request.recentSourceLanguages)
        ...candidates.where((c) => _sameLanguage(c, code)),
    ];
    final ordered = {...recent, ...candidates};
    return result.copyWith(
      detectionUncertain: true,
      detectedAlternatives: List.unmodifiable(ordered.take(3)),
    );
  }

  /// Whether two language codes name the same language (ignoring region
  /// and script).
  static bool _sameLanguage(String a, String b) =>
      _primarySubtag(a) == _primarySubtag(b);

  static String _primarySubtag(String code) =>
      LanguageMatcher.normalize(code).split('-').first.toLowerCase();

  /// Runs [engines] concurrently and emits a [CompareEntry] per engine as
  /// soon as it finishes (only final results; failures as
  /// `CompareEntry.failure`). Every engine is translated on its own, like
  /// [translate] (so results come from and go to the cache; short input
  /// gets no second language detection): Mozhi engines get one
  /// single-engine request each, because `engine=all` and comma-separated
  /// lists crash Mozhi servers whose DuckDuckGo upstream is
  /// unreachable (mozhi-contract G1) and drop failures silently.
  Stream<CompareEntry> compare(
    List<TranslationEngine> engines,
    TranslationRequest request, {
    bool refresh = false,
  }) {
    final unique = {for (final engine in engines) engine.id: engine}.values;
    if (request.text.trim().isEmpty || unique.isEmpty) {
      return const Stream.empty();
    }
    final subscriptions = <StreamSubscription<TranslationResult>>[];
    late final StreamController<CompareEntry> controller;
    var cancelled = false;

    void emit(CompareEntry entry) {
      if (!cancelled && !controller.isClosed) controller.add(entry);
    }

    // Only the final result of an AI stream is complete; every stream
    // closes after an error.
    Future<void> run(TranslationEngine engine) {
      final completer = Completer<void>();
      var reported = false;
      void report(CompareEntry entry) {
        if (reported) return;
        reported = true;
        emit(entry);
      }

      subscriptions.add(
        _translate(engine, request, refresh: refresh, detectionHint: false)
            .where((result) => result.isComplete)
            .listen(
              (result) => report(CompareEntry.success(result)),
              onError: (Object error) => report(
                CompareEntry.failure(
                  engineId: engine.id,
                  engineName: engine.name,
                  error: error,
                ),
              ),
              onDone: completer.complete,
            ),
      );
      return completer.future;
    }

    controller = StreamController<CompareEntry>(
      onListen: () {
        unawaited(
          Future.wait(unique.map(run)).whenComplete(() {
            if (!controller.isClosed) unawaited(controller.close());
          }),
        );
      },
      onCancel: () async {
        cancelled = true;
        await Future.wait([
          for (final subscription in subscriptions) subscription.cancel(),
        ]);
      },
    );
    return controller.stream;
  }

  Future<AlternativeTranslations> getAlternatives(
    TranslationEngine engine,
    TranslationRequest request,
    String translation, {
    int count = 3,
    String? span,
    String uiLanguage = 'English',
  }) => _chatJson(
    engine,
    () => TranslationPrompts.alternatives(
      request,
      translation,
      count: count,
      span: span,
      uiLanguage: uiLanguage,
    ),
    ResponseParsers.parseAlternatives,
  );

  Future<List<WordInsight>> getInsights(
    TranslationEngine engine,
    TranslationRequest request,
    String translation, {
    String uiLanguage = 'English',
  }) => _chatJson(
    engine,
    () => TranslationPrompts.insights(
      request,
      translation,
      uiLanguage: uiLanguage,
    ),
    (output) => ResponseParsers.parseInsights(output, translation: translation),
  );

  Future<List<RefinementSuggestion>> getSuggestions(
    TranslationEngine engine,
    TranslationRequest request,
    String translation, {
    String uiLanguage = 'English',
  }) => _chatJson(
    engine,
    () => TranslationPrompts.suggestions(
      request,
      translation,
      uiLanguage: uiLanguage,
    ),
    ResponseParsers.parseSuggestions,
  );

  /// Streams Markdown as text deltas (concatenate them for the full text).
  /// Requires an AI engine with [TranslationEngine.supportsExtras] (an
  /// [ArgumentError] stream error otherwise).
  Stream<String> explain(
    TranslationEngine engine,
    TranslationRequest request,
    String translation, {
    String? question,
    String uiLanguage = 'English',
  }) async* {
    final config = _extrasProviderFor(engine);
    yield* _llm
        .clientFor(config)
        .streamChat(
          _llmRequest(
            config,
            TranslationPrompts.explain(
              request,
              translation,
              question: question,
              uiLanguage: uiLanguage,
            ),
          ),
        );
  }

  /// A dictionary entry for [word] (definitions in [uiLanguage],
  /// translations into [target]). [verbosity] sets how many senses,
  /// examples and notes are asked for. [DictionaryEntry.didYouMean] holds
  /// the corrected spelling when [word] looks misspelled.
  Future<DictionaryEntry> lookUp(
    TranslationEngine engine,
    String word, {
    required Language source,
    required Language target,
    String context = '',
    String uiLanguage = 'English',
    DictionaryVerbosity verbosity = DictionaryVerbosity.standard,
  }) => _chatJson(
    engine,
    () => TranslationPrompts.dictionary(
      word,
      source: source,
      targetLanguage: target,
      context: context,
      uiLanguage: uiLanguage,
      verbosity: verbosity,
    ),
    (output) => ResponseParsers.parseDictionary(output, query: word),
  );

  // Round 3 extras.

  /// Revises [currentTranslation] of [request] according to [instruction]
  /// ("More formal", "Shorter", a suggestion's instruction, ...) instead of
  /// translating again: the model makes minimal edits and keeps the
  /// meaning, glossary terms, formatting and placeholders (see
  /// `TranslationPrompts.refine`).
  ///
  /// Streams snapshots exactly like [translate] for AI engines (growing
  /// `isComplete: false` snapshots, then one `isComplete: true` result
  /// cleaned with `ResponseParsers.cleanTranslation`; `detectedSource` from
  /// the `[[lang:xx]]` marker when the source is auto). Results are never
  /// cached. Empty/whitespace [TranslationRequest.text] emits nothing.
  ///
  /// Errors are stream errors: an [ArgumentError] for engines that are not
  /// AI engines, unknown providers, a blank [instruction] or
  /// [currentTranslation], or an empty custom language name; an
  /// [UnsupportedError] for translation-specialised models
  /// ([TranslationEngine.usesMtProfile]: TranslateGemma, Hy-MT), which
  /// cannot follow instructions (re-translate with [translate] instead);
  /// provider errors as-is. Cancelling the subscription cancels the HTTP
  /// request.
  Stream<TranslationResult> refine(
    TranslationEngine engine,
    TranslationRequest request, {
    required String currentTranslation,
    required String instruction,
  }) async* {
    if (request.text.trim().isEmpty) return;
    final config = _aiProviderFor(engine);
    if (config.resolvedPromptProfile.isTranslationOnly) {
      throw UnsupportedError(
        '${engine.name} only supports plain translation and cannot refine '
        'a translation; translate again instead.',
      );
    }
    final safe = _sanitizeRequest(request);
    if (safe == null) throw _emptyCustomLanguage(request);
    final messages = TranslationPrompts.refine(
      safe,
      currentTranslation: currentTranslation,
      instruction: instruction,
    );
    yield* aiTranslationStream(
      open: () =>
          _llm.clientFor(config).streamChat(_llmRequest(config, messages)),
      engine: engine,
      request: safe,
      snapshotInterval: _snapshotInterval,
    );
  }

  /// [text] (in [language], which may be auto) in the Latin script, using
  /// the standard romanization of the language (`TranslationPrompts
  /// .romanizationSystem`: Hepburn, Hanyu Pinyin with tone marks, Revised
  /// Romanization, ISO 15919 / IAST, ALA-LC, ...), with line breaks kept.
  ///
  /// Text without letters of a non-Latin script
  /// (`LanguageCatalog.hasNonLatinLetters`) is returned unchanged without a
  /// request; use `LanguageCatalog.usesNonLatinScript` to decide when to
  /// offer romanization. Requires an AI engine with
  /// [TranslationEngine.supportsExtras] ([ArgumentError] otherwise). An
  /// empty reply is an `LlmApiException`.
  Future<String> romanize(
    TranslationEngine engine, {
    required String text,
    required Language language,
  }) async {
    final config = _extrasProviderFor(engine);
    if (!LanguageCatalog.hasNonLatinLetters(text)) return text;
    final output = await _llm
        .clientFor(config)
        .chat(
          _llmRequest(
            config,
            TranslationPrompts.romanize(text, language: language),
          ),
        );
    final romanized = ResponseParsers.cleanRomanization(output, source: text);
    if (romanized.trim().isEmpty) {
      throw const LlmApiException('The model returned an empty response.');
    }
    return romanized;
  }

  /// Which phrases of [source] and its [translation] correspond, as
  /// character ranges in both texts (for highlighting a phrase and its
  /// counterpart). The model lists the corresponding phrases; they are
  /// located in the texts by `ResponseParsers.parseAlignment` (pairs it
  /// cannot locate are dropped).
  ///
  /// Only the first `TranslationPrompts.maxAlignmentChars` (3000)
  /// characters of each text are sent, so longer texts are aligned only at
  /// their beginning. Blank texts give an empty list without a request.
  /// Requires an AI engine with [TranslationEngine.supportsExtras]
  /// ([ArgumentError] otherwise); invalid JSON is retried once, like the
  /// other JSON extras.
  Future<List<AlignedSpan>> align(
    TranslationEngine engine, {
    required String source,
    required String translation,
    required Language sourceLanguage,
    required Language targetLanguage,
  }) async {
    if (source.trim().isEmpty || translation.trim().isEmpty) {
      _extrasProviderFor(engine);
      return const [];
    }
    return await _chatJson(
      engine,
      () => TranslationPrompts.align(
        source: source,
        translation: translation,
        sourceLanguage: sourceLanguage,
        targetLanguage: targetLanguage,
      ),
      (output) => ResponseParsers.parseAlignment(
        output,
        source: source,
        translation: translation,
      ),
    );
  }

  Future<ProofreadResult> proofread(
    TranslationEngine engine,
    String text, {
    WritingStyle style = WritingStyle.general,
    CorrectionLevel level = CorrectionLevel.standard,
    Formality formality = Formality.automatic,
    String context = '',
    String uiLanguage = 'English',
  }) => _chatJson(
    engine,
    () => TranslationPrompts.proofread(
      text,
      style: style,
      level: level,
      formality: formality,
      context: context,
      uiLanguage: uiLanguage,
    ),
    (output) => ResponseParsers.parseProofread(output, input: text),
  );

  /// Uses the AI [engine] when it [TranslationEngine.supportsExtras]; the
  /// on-device identifier when [engine] is the offline engine; else Mozhi
  /// google with `from=auto` (taking `detected`); else the on-device
  /// identifier when available ([SourceLanguageRequiredException] when it
  /// cannot tell); else throws a [StateError].
  Future<DetectedLanguage> detectLanguage(
    String text, {
    TranslationEngine? engine,
  }) async {
    if (engine != null && engine.supportsExtras) {
      return await _chatJson(
        engine,
        () => TranslationPrompts.detectLanguage(text),
        ResponseParsers.parseDetectedLanguage,
      );
    }
    final offline = _offline;
    final onDevice = offline != null && offline.isAvailable;
    if (onDevice &&
        ((engine?.isOffline ?? false) || _mozhi.instances.isEmpty)) {
      final code = normalizeDetected(
        await offline.translator.identifyLanguage(text),
      );
      if (code == null) {
        throw SourceLanguageRequiredException(engineId: engine?.id);
      }
      return DetectedLanguage(code: code);
    }
    if (_mozhi.instances.isEmpty) {
      throw StateError(
        'Language detection needs an AI engine or a Mozhi instance.',
      );
    }
    return await _detectWithMozhi(text);
  }

  Future<DetectedLanguage> _detectWithMozhi(String text) async {
    final translation = await _mozhi.run(
      (client, _) => client.translate(
        engine: 'google',
        from: 'auto',
        to: 'en',
        text: text,
      ),
      failOverOnTimeout: false,
    );
    final code = normalizeDetected(translation.detectedLanguage);
    if (code == null) {
      throw const MozhiApiException('The language could not be detected.');
    }
    return DetectedLanguage(code: code);
  }

  /// Mozhi `/api/tts` on the active instance with failover (not after a
  /// timeout). [engine] is `google` (default) or `reverso`. When Google
  /// fails on every instance, Reverso is tried before giving up (the Google
  /// error is rethrown).
  Future<Uint8List> textToSpeech({
    required String text,
    required String languageCode,
    String engine = 'google',
  }) async {
    Future<Uint8List> speak(String ttsEngine) => _mozhi.run(
      (client, _) => client.textToSpeech(
        engine: ttsEngine,
        language: languageCode,
        text: text,
      ),
      failOverOnTimeout: false,
    );
    try {
      return await speak(engine);
    } on Object catch (error, stackTrace) {
      if (engine != 'google' || _mozhi.instances.isEmpty) rethrow;
      try {
        return await speak('reverso');
      } on Object {
        Error.throwWithStackTrace(error, stackTrace);
      }
    }
  }

  /// AI engine with vision: `TranslationPrompts.translateImage` (not for
  /// translation-specialised models). Mozhi engine: `/api/image` (requires
  /// PNG; Google only, so the Google engine is used whichever Mozhi engine
  /// is passed). Other engines throw an [ArgumentError]: an image picked for
  /// the offline or a machine translation engine is never sent to Mozhi.
  Future<ImageTranslationResult> translateImage(
    TranslationEngine engine,
    Uint8List imageBytes, {
    required String mimeType,
    required Language source,
    required Language target,
    TranslationOptions options = const TranslationOptions(),
  }) async {
    if (engine.isAi) {
      final config = _extrasProviderFor(engine);
      final safe = _sanitizeRequest(
        TranslationRequest(text: '', source: source, target: target),
      );
      if (safe == null) {
        throw _emptyCustomLanguage(
          TranslationRequest(text: '', source: source, target: target),
        );
      }
      final output = await _llm
          .clientFor(config)
          .chat(
            _llmRequest(
              config,
              TranslationPrompts.translateImage(
                imageBytes,
                mimeType: mimeType,
                source: safe.source,
                target: safe.target,
                options: options,
              ),
            ),
          );
      final split = ResponseParsers.splitLanguageMarker(output);
      return ImageTranslationResult(
        translatedText: ResponseParsers.cleanTranslation(
          split.text,
          source: '',
        ),
      );
    }
    if (!engine.isMozhi) {
      throw ArgumentError.value(
        engine.id,
        'engine',
        'Image translation requires an AI or Mozhi engine',
      );
    }
    _checkMozhiLanguages(source, target);
    if (mimeType.toLowerCase() != 'image/png') {
      throw ArgumentError.value(
        mimeType,
        'mimeType',
        'Mozhi image translation requires a PNG image',
      );
    }
    final translation = await _mozhi.run(
      (client, _) => client.translateImage(
        pngBytes: imageBytes,
        from: source.code,
        to: target.code,
      ),
      failOverOnTimeout: false,
    );
    return ImageTranslationResult(
      translatedImage: decodeBase64Image(translation.translatedImageBase64),
      sourceText: translation.sourceText,
      translatedText: translation.translatedText,
    );
  }

  /// Latency of `/api/version` on [instance]; throws on failure.
  Future<Duration> pingInstance(MozhiInstance instance) =>
      _mozhi.withClient(instance, (client) => client.ping());

  /// The models of an AI provider; machine translation services have none
  /// (an empty list).
  Future<List<LlmModel>> listModels(AiProviderConfig config) async {
    if (config.isMtService) return const [];
    return await _llm.withTemporaryClient(
      config,
      (client) => client.listModels(),
    );
  }

  /// Sends a tiny translation ("Hello" -> French) with [config]; returns the
  /// output; throws the provider error on failure. Machine translation
  /// services use their API; translation-specialised models get their own
  /// prompt template.
  Future<String> testProvider(AiProviderConfig config) {
    if (config.isMtService) return _mt.test(config);
    return _llm.withTemporaryClient(config, (client) async {
      const request = TranslationRequest(
        text: 'Hello, world!',
        source: Language(code: 'en', name: 'English'),
        target: Language(code: 'fr', name: 'French'),
      );
      final profile = config.resolvedPromptProfile;
      final translationOnly = profile.isTranslationOnly;
      final output = await client.chat(
        _llmRequest(
          config,
          translationOnly
              ? MtPrompts.translate(profile, request)
              : TranslationPrompts.translate(request),
          defaultTemperature: translationOnly
              ? MtPrompts.sampling(profile).temperature
              : null,
        ),
      );
      final text = ResponseParsers.cleanTranslation(
        translationOnly
            ? output
            : ResponseParsers.splitLanguageMarker(output).text,
        source: request.text,
      );
      if (text.trim().isEmpty) {
        throw const LlmApiException('The model returned an empty response.');
      }
      return text;
    });
  }

  /// Closes all cached HTTP clients and empties the caches.
  void dispose() {
    _clearMozhiCaches();
    _cache.clear();
    _mozhi.dispose();
    _llm.dispose();
    _mt.dispose();
  }

  /// The configuration of AI [engine]; [ArgumentError] for other kinds and
  /// unknown providers.
  AiProviderConfig _aiProviderFor(TranslationEngine engine) {
    if (!engine.isAi) {
      throw ArgumentError.value(engine.id, 'engine', 'Requires an AI engine');
    }
    final config = _configFor(engine, 'ai:');
    if (config == null || config.isMtService) {
      throw ArgumentError.value(engine.id, 'engine', 'Unknown AI provider');
    }
    return config;
  }

  /// Like [_aiProviderFor], but also rejects translation-specialised models,
  /// which cannot follow the extras' prompts.
  AiProviderConfig _extrasProviderFor(TranslationEngine engine) {
    final config = _aiProviderFor(engine);
    if (config.resolvedPromptProfile.isTranslationOnly) {
      throw ArgumentError.value(
        engine.id,
        'engine',
        'This model only supports plain translation',
      );
    }
    return config;
  }

  /// The configuration of machine translation [engine] (callers dispatch on
  /// [EngineKind.mt]); [ArgumentError] for unknown providers.
  AiProviderConfig _mtProviderFor(TranslationEngine engine) {
    final config = _configFor(engine, 'mt:');
    if (config == null || !config.isMtService) {
      throw ArgumentError.value(
        engine.id,
        'engine',
        'Unknown machine translation service',
      );
    }
    return config;
  }

  AiProviderConfig? _configFor(TranslationEngine engine, String prefix) {
    final id =
        engine.providerId ??
        (engine.id.startsWith(prefix)
            ? engine.id.substring(prefix.length)
            : engine.id);
    return _providers.firstWhereOrNull((p) => p.id == id);
  }

  OfflineEngine _offlineFor(TranslationEngine engine) {
    final offline = _offline;
    if (!engine.isOffline || offline == null) {
      throw ArgumentError.value(
        engine.id,
        'engine',
        'No offline translator is configured',
      );
    }
    return offline;
  }

  static void _checkMozhiLanguages(Language source, Language target) {
    if (source.isCustom || target.isCustom) {
      throw ArgumentError.value(
        (source.isCustom ? source : target).code,
        source.isCustom ? 'source' : 'target',
        'Custom languages require an AI engine',
      );
    }
  }

  /// Anthropic models reject non-default sampling parameters, so the
  /// temperature is never sent to them. Elsewhere the provider's own
  /// temperature wins over [defaultTemperature] (a model card's
  /// recommendation).
  static LlmRequest _llmRequest(
    AiProviderConfig config,
    List<LlmMessage> messages, {
    bool jsonOutput = false,
    double? defaultTemperature,
  }) => LlmRequest(
    model: config.model,
    messages: messages,
    temperature: config.provider == LlmProvider.anthropic
        ? null
        : config.temperature ?? defaultTemperature,
    effort: config.effort,
    jsonOutput: jsonOutput,
  );

  /// Non-streaming JSON request; on a [FormatException] from [parse] asks
  /// once more for valid JSON only.
  Future<T> _chatJson<T>(
    TranslationEngine engine,
    List<LlmMessage> Function() messages,
    T Function(String output) parse,
  ) async {
    final config = _extrasProviderFor(engine);
    final client = _llm.clientFor(config);
    final request = _llmRequest(config, messages(), jsonOutput: true);
    final output = await client.chat(request);
    try {
      return parse(output);
    } on FormatException {
      final retry = await client.chat(
        request.copyWith(
          messages: [
            ...request.messages,
            if (output.trim().isNotEmpty) LlmMessage.assistant(output),
            const LlmMessage.user(_jsonRetryInstruction),
          ],
        ),
      );
      return parse(retry);
    }
  }
}
