import 'dart:async';
import 'dart:typed_data';

import 'package:collection/collection.dart';
import 'package:llm_api/llm_api.dart';
import 'package:mozhi_api/mozhi_api.dart';
import 'package:translation_repository/src/language_catalog.dart';
import 'package:translation_repository/src/models/models.dart';
import 'package:translation_repository/src/prompts/response_parsers.dart';
import 'package:translation_repository/src/prompts/translation_prompts.dart';
import 'package:translation_repository/src/repository/ai_translation_stream.dart';
import 'package:translation_repository/src/repository/llm_pool.dart';
import 'package:translation_repository/src/repository/mappers.dart';
import 'package:translation_repository/src/repository/mozhi_pool.dart';

typedef MozhiClientFactory = MozhiApiClient Function(Uri baseUrl);
typedef LlmClientFactory = LlmClient Function(LlmEndpoint endpoint);

/// The single entry point the app uses for anything translation related.
///
/// Configuration is pushed by the app whenever settings change
/// ([updateConfiguration]). Mozhi requests go to the first reachable
/// instance in [instances] order: on a retryable `MozhiApiException`
/// (network/timeout/429/5xx) the next instance is tried and, on success,
/// becomes the preferred one for the session ([activeInstance]).
/// Language lists and engine lists are cached in memory per instance+engine
/// (cleared by [updateConfiguration] when instances change, or
/// `refresh: true`).
class TranslationRepository {
  /// [mozhiClientFactory] / [llmClientFactory] create the HTTP clients
  /// (defaults: `MozhiApiClient(baseUrl: ...)` / `LlmClient(endpoint)`).
  /// Clients are cached per Mozhi instance URL and per AI provider
  /// connection settings.
  ///
  /// `snapshotInterval` throttles intermediate AI streaming snapshots.
  new({
    MozhiClientFactory? mozhiClientFactory,
    LlmClientFactory? llmClientFactory,
    this._snapshotInterval = const Duration(milliseconds: 50),
  }) : _mozhi = MozhiPool(mozhiClientFactory ?? _defaultMozhiClient),
       _llm = LlmPool(llmClientFactory ?? _defaultLlmClient);

  static MozhiApiClient _defaultMozhiClient(Uri baseUrl) =>
      MozhiApiClient(baseUrl: baseUrl);

  static LlmClient _defaultLlmClient(LlmEndpoint endpoint) =>
      LlmClient(endpoint);

  final MozhiPool _mozhi;
  final LlmPool _llm;
  final Duration _snapshotInterval;
  List<AiProviderConfig> _providers = const [];

  Future<List<TranslationEngine>>? _mozhiEngines;
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
    _providers = List.unmodifiable(providers);
    _llm.update(providers);
  }

  List<MozhiInstance> get instances => _mozhi.instances;
  List<AiProviderConfig> get providers => _providers;

  /// Instance currently preferred for Mozhi calls (null when none).
  MozhiInstance? get activeInstance => _mozhi.active;

  /// Engines: Mozhi engines advertised by the active instance (via
  /// `/api/engines`, `subtitle` = instance host) followed by enabled AI
  /// providers (`name` = provider name, `subtitle` = model, `isLocal`).
  /// If no instance is reachable, returns only AI engines (and does not
  /// throw) unless there are none, in which case the last error is thrown.
  Future<List<TranslationEngine>> getEngines({bool refresh = false}) async {
    if (refresh) _clearMozhiCaches();
    final ai = [
      for (final provider in _providers)
        if (provider.enabled)
          TranslationEngine(
            id: 'ai:${provider.id}',
            kind: EngineKind.ai,
            name: provider.name,
            subtitle: provider.model,
            providerId: provider.id,
            isLocal: provider.isLocal,
          ),
    ];
    if (_mozhi.instances.isEmpty) return ai;
    try {
      return [...await _loadMozhiEngines(), ...ai];
    } on Object {
      if (ai.isEmpty) rethrow;
      return ai;
    }
  }

  Future<List<TranslationEngine>> _loadMozhiEngines() {
    final cached = _mozhiEngines;
    if (cached != null) return cached;
    final future = _mozhi.run((client, instance) async {
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
    _mozhiEngines = future;
    unawaited(
      future.then<void>(
        (_) {},
        onError: (Object _) {
          if (identical(_mozhiEngines, future)) _mozhiEngines = null;
        },
      ),
    );
    return future;
  }

  void _clearMozhiCaches() {
    _mozhiEngines = null;
    _languages.clear();
  }

  /// Mozhi: `/api/source_languages` mapped to [Language] (id `auto` ->
  /// [Language.auto] first, names from the engine, `nativeName` from
  /// `LanguageCatalog` when known). AI: [Language.auto] + catalogue.
  Future<List<Language>> getSourceLanguages(TranslationEngine engine) =>
      engine.isAi
      ? Future.sync(() => [Language.auto, ...LanguageCatalog.all])
      : _mozhiLanguages(engine, source: true);

  /// Mozhi: `/api/target_languages`. AI: catalogue.
  Future<List<Language>> getTargetLanguages(TranslationEngine engine) =>
      engine.isAi
      ? Future.sync(() => LanguageCatalog.all)
      : _mozhiLanguages(engine, source: false);

  Future<List<Language>> _mozhiLanguages(
    TranslationEngine engine, {
    required bool source,
  }) {
    final id = mozhiEngineId(engine);
    final key = [
      _mozhi.active?.url ?? '',
      id,
      if (source) 'source' else 'target',
    ].join('|');
    final cached = _languages[key];
    if (cached != null) return cached;
    final future = _mozhi.run((client, _) async {
      final languages = source
          ? await client.getSourceLanguages(id)
          : await client.getTargetLanguages(id);
      return List<Language>.unmodifiable(mapMozhiLanguages(languages));
    });
    _languages[key] = future;
    unawaited(
      future.then<void>(
        (_) {},
        onError: (Object _) {
          _languages.removeWhere((_, value) => identical(value, future));
        },
      ),
    );
    return future;
  }

  /// Mozhi: one complete result (with transliterations, word choices,
  /// synonyms; `detectedSource` normalised). AI: streams growing snapshots
  /// (`isComplete: false`) and a final `isComplete: true` result; the
  /// `[[lang:xx]]` marker is parsed into `detectedSource` and never shown;
  /// `<think>` content never appears; text is passed through
  /// `ResponseParsers.cleanTranslation` on completion. Empty/whitespace
  /// input emits nothing and completes. Errors are forwarded as-is
  /// (`MozhiApiException`, `LlmApiException`, `LlmRefusalException`).
  /// Cancelling the subscription cancels the underlying HTTP request.
  ///
  /// A custom target language on a Mozhi engine is reported as an
  /// [ArgumentError] stream error.
  Stream<TranslationResult> translate(
    TranslationEngine engine,
    TranslationRequest request,
  ) {
    if (request.text.trim().isEmpty) return const Stream.empty();
    if (engine.isMozhi) {
      return Stream.fromFuture(_translateMozhi(engine, request));
    }
    return aiTranslationStream(
      open: () {
        final config = _providerFor(engine);
        return _llm
            .clientFor(config)
            .streamChat(
              _llmRequest(config, TranslationPrompts.translate(request)),
            );
      },
      engine: engine,
      request: request,
      snapshotInterval: _snapshotInterval,
    );
  }

  Future<TranslationResult> _translateMozhi(
    TranslationEngine engine,
    TranslationRequest request,
  ) async {
    _checkMozhiLanguages(request.source, request.target);
    final stopwatch = Stopwatch()..start();
    final translation = await _mozhi.run(
      (client, _) => client.translate(
        engine: mozhiEngineId(engine),
        from: request.source.code,
        to: request.target.code,
        text: request.text,
      ),
    );
    return mapMozhiTranslation(
      engine,
      request,
      translation,
      elapsed: stopwatch.elapsed,
    );
  }

  /// Runs [engines] concurrently and emits a [CompareEntry] per engine as
  /// soon as it finishes (only final results; failures as
  /// `CompareEntry.failure`). Mozhi engines are batched into a single
  /// `translateWithEngines` call when 2+ Mozhi engines are requested, with
  /// engines missing from the batch response reported as failures.
  Stream<CompareEntry> compare(
    List<TranslationEngine> engines,
    TranslationRequest request,
  ) {
    final unique = {for (final engine in engines) engine.id: engine}.values;
    if (request.text.trim().isEmpty || unique.isEmpty) {
      return const Stream.empty();
    }
    final mozhi = unique.where((e) => e.isMozhi).toList();
    final ai = unique.where((e) => e.isAi).toList();
    final subscriptions = <StreamSubscription<TranslationResult>>[];
    late final StreamController<CompareEntry> controller;
    var cancelled = false;

    void emit(CompareEntry entry) {
      if (!cancelled && !controller.isClosed) controller.add(entry);
    }

    CompareEntry failure(TranslationEngine engine, Object error) =>
        CompareEntry.failure(
          engineId: engine.id,
          engineName: engine.name,
          error: error,
        );

    Future<void> runMozhi(TranslationEngine engine) async {
      try {
        emit(CompareEntry.success(await _translateMozhi(engine, request)));
      } on Object catch (error) {
        emit(failure(engine, error));
      }
    }

    Future<void> runMozhiBatch(List<TranslationEngine> batch) async {
      try {
        _checkMozhiLanguages(request.source, request.target);
        final stopwatch = Stopwatch()..start();
        final results = await _mozhi.run(
          (client, _) => client.translateWithEngines(
            engines: [for (final engine in batch) mozhiEngineId(engine)],
            from: request.source.code,
            to: request.target.code,
            text: request.text,
          ),
        );
        final elapsed = stopwatch.elapsed;
        for (final engine in batch) {
          final id = mozhiEngineId(engine).toLowerCase();
          final translation = results.firstWhereOrNull(
            (r) => r.engine.toLowerCase() == id,
          );
          emit(
            translation == null
                ? failure(
                    engine,
                    MozhiApiException('${engine.name} returned no result.'),
                  )
                : CompareEntry.success(
                    mapMozhiTranslation(
                      engine,
                      request,
                      translation,
                      elapsed: elapsed,
                    ),
                  ),
          );
        }
      } on Object catch (error) {
        for (final engine in batch) {
          emit(failure(engine, error));
        }
      }
    }

    Future<void> runAi(TranslationEngine engine) {
      final completer = Completer<void>();
      TranslationResult? last;
      subscriptions.add(
        translate(engine, request).listen(
          (result) => last = result,
          onError: (Object error) {
            emit(failure(engine, error));
            completer.complete();
          },
          onDone: () {
            final result = last;
            emit(
              result != null && result.isComplete
                  ? CompareEntry.success(result)
                  : failure(
                      engine,
                      const LlmApiException('The model returned no result.'),
                    ),
            );
            if (!completer.isCompleted) completer.complete();
          },
          cancelOnError: true,
        ),
      );
      return completer.future;
    }

    controller = StreamController<CompareEntry>(
      onListen: () {
        final tasks = [
          if (mozhi.length >= 2)
            runMozhiBatch(mozhi)
          else
            ...mozhi.map(runMozhi),
          ...ai.map(runAi),
        ];
        unawaited(
          Future.wait(tasks).whenComplete(() {
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
  /// Requires an AI engine (an [ArgumentError] stream error otherwise).
  Stream<String> explain(
    TranslationEngine engine,
    TranslationRequest request,
    String translation, {
    String? question,
    String uiLanguage = 'English',
  }) async* {
    final config = _providerFor(engine);
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

  Future<DictionaryEntry> lookUp(
    TranslationEngine engine,
    String word, {
    required Language source,
    required Language target,
    String context = '',
    String uiLanguage = 'English',
  }) => _chatJson(
    engine,
    () => TranslationPrompts.dictionary(
      word,
      source: source,
      targetLanguage: target,
      context: context,
      uiLanguage: uiLanguage,
    ),
    ResponseParsers.parseDictionary,
  );

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

  /// Uses the AI [engine] when given, else Mozhi google with `from=auto`
  /// (taking `detected`), else throws.
  Future<DetectedLanguage> detectLanguage(
    String text, {
    TranslationEngine? engine,
  }) async {
    if (engine != null && engine.isAi) {
      return await _chatJson(
        engine,
        () => TranslationPrompts.detectLanguage(text),
        ResponseParsers.parseDetectedLanguage,
      );
    }
    if (_mozhi.instances.isEmpty) {
      throw StateError(
        'Language detection needs an AI engine or a Mozhi instance.',
      );
    }
    final translation = await _mozhi.run(
      (client, _) => client.translate(
        engine: 'google',
        from: 'auto',
        to: 'en',
        text: text,
      ),
    );
    final code = normalizeDetected(translation.detectedLanguage);
    if (code == null) {
      throw const MozhiApiException('The language could not be detected.');
    }
    return DetectedLanguage(code: code);
  }

  /// Mozhi `/api/tts` on the active instance with failover. [engine] is
  /// `google` (default) or `reverso`. When Google fails on every instance,
  /// Reverso is tried before giving up (the Google error is rethrown).
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

  /// AI engine with vision: `TranslationPrompts.translateImage`.
  /// Mozhi engine: `/api/image` (requires PNG; Google only, so the Google
  /// engine is used whichever Mozhi engine is passed).
  Future<ImageTranslationResult> translateImage(
    TranslationEngine engine,
    Uint8List imageBytes, {
    required String mimeType,
    required Language source,
    required Language target,
    TranslationOptions options = const TranslationOptions(),
  }) async {
    if (engine.isAi) {
      final config = _providerFor(engine);
      final output = await _llm
          .clientFor(config)
          .chat(
            _llmRequest(
              config,
              TranslationPrompts.translateImage(
                imageBytes,
                mimeType: mimeType,
                source: source,
                target: target,
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

  Future<List<LlmModel>> listModels(AiProviderConfig config) =>
      _llm.withTemporaryClient(config, (client) => client.listModels());

  /// Sends a tiny translation ("Hello" -> French) with [config]; returns the
  /// output; throws the provider error on failure.
  Future<String> testProvider(AiProviderConfig config) =>
      _llm.withTemporaryClient(config, (client) async {
        const request = TranslationRequest(
          text: 'Hello, world!',
          source: Language(code: 'en', name: 'English'),
          target: Language(code: 'fr', name: 'French'),
        );
        final output = await client.chat(
          _llmRequest(config, TranslationPrompts.translate(request)),
        );
        final text = ResponseParsers.cleanTranslation(
          ResponseParsers.splitLanguageMarker(output).text,
          source: request.text,
        );
        if (text.trim().isEmpty) {
          throw const LlmApiException('The model returned an empty response.');
        }
        return text;
      });

  /// Closes all cached HTTP clients.
  void dispose() {
    _clearMozhiCaches();
    _mozhi.dispose();
    _llm.dispose();
  }

  /// The configuration of AI [engine]; [ArgumentError] for Mozhi engines and
  /// unknown providers.
  AiProviderConfig _providerFor(TranslationEngine engine) {
    if (!engine.isAi) {
      throw ArgumentError.value(engine.id, 'engine', 'Requires an AI engine');
    }
    final id =
        engine.providerId ??
        (engine.id.startsWith('ai:') ? engine.id.substring(3) : engine.id);
    final config = _providers.firstWhereOrNull((p) => p.id == id);
    if (config == null) {
      throw ArgumentError.value(engine.id, 'engine', 'Unknown AI provider');
    }
    return config;
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
  /// temperature is never sent to them.
  static LlmRequest _llmRequest(
    AiProviderConfig config,
    List<LlmMessage> messages, {
    bool jsonOutput = false,
  }) => LlmRequest(
    model: config.model,
    messages: messages,
    temperature: config.provider == LlmProvider.anthropic
        ? null
        : config.temperature,
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
    final config = _providerFor(engine);
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
