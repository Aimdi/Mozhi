import 'dart:async';

import 'package:bloc/bloc.dart';
import 'package:mozhi/history/cubit/history_cubit.dart';
import 'package:mozhi/history/models/history_entry.dart';
import 'package:mozhi/settings/cubit/settings_cubit.dart';
import 'package:mozhi/translate/cubit/translate_state.dart';
import 'package:translation_repository/translation_repository.dart';

export 'translate_state.dart';

/// The optional AI extras, each with its own request token so that a stale
/// response (input/result changed meanwhile) is dropped.
enum _Extra { alternatives, insights, suggestions, explain, dictionary }

/// Drives the translate screen.
///
/// * Reads initial engine/languages/options from `settings` and writes
///   selection changes back (`setEngine`, `setLanguages`,
///   `addRecentLanguage`, `setOptions`).
/// * Typing ([setInput]) debounces and auto-translates when
///   `instantTranslate` (Mozhi) / `instantTranslateAi` (AI) is on; any new
///   translation cancels the in-flight one (stream subscription cancel).
/// * Completed translations are added to `history` when `saveHistory`.
/// * Changing text/engine/languages/options clears extras.
/// * When the detected language equals the target (auto source), the target
///   switches to the most recent other language (Kagi/Google smart swap).
///
/// The constructor does no async work: call [loadEngines] once after
/// construction (and whenever instances/providers change).
class TranslateCubit extends Cubit<TranslateState> {
  new({
    required this._repository,
    required SettingsCubit settings,
    required this._history,
    this.debounce = const Duration(milliseconds: 600),
    this.aiDebounce = const Duration(milliseconds: 1200),
  }) : _settings = settings,
       super(
         TranslateState(
           source: settings.state.source,
           target: settings.state.target,
           options: settings.state.options,
         ),
       );

  static const _english = Language(code: 'en', name: 'English');
  static const _defaultEngineId = 'mozhi:google';

  final TranslationRepository _repository;
  final SettingsCubit _settings;
  final HistoryCubit _history;

  /// Instant-translate delay for Mozhi engines.
  final Duration debounce;

  /// Instant-translate delay for AI engines.
  final Duration aiDebounce;

  Timer? _debounceTimer;
  int _enginesRequest = 0;

  StreamSubscription<TranslationResult>? _translation;
  Completer<void>? _translationDone;
  int _translationRequest = 0;

  StreamSubscription<CompareEntry>? _compare;
  Completer<void>? _compareDone;
  int _compareRequest = 0;

  StreamSubscription<String>? _explanation;
  Completer<void>? _explanationDone;
  final _extraRequests = <_Extra, int>{};

  /// Normalised target code the last smart swap switched away from.
  String? _smartSwappedFrom;

  /// Normalised code the user explicitly re-selected after a smart swap;
  /// no further smart swaps away from it this session.
  String? _smartSwapDeclined;

  // ---------------------------------------------------------------------
  // Engines
  // ---------------------------------------------------------------------

  /// Loads engines + language lists for the selected engine. Call on start
  /// and whenever instances/providers change ([refresh] forces refetch).
  Future<void> loadEngines({bool refresh = false}) async {
    final request = ++_enginesRequest;
    emit(state.copyWith(enginesStatus: EnginesStatus.loading));
    try {
      final engines = await _repository.getEngines(refresh: refresh);
      if (!_isCurrentEngines(request)) return;
      if (engines.isEmpty) {
        _cancelTranslation();
        emit(
          _clearedExtras(state).copyWith(
            enginesStatus: EnginesStatus.ready,
            engines: const [],
            engine: () => null,
            assistEngine: () => null,
            status: TranslateStatus.idle,
            result: () => null,
            error: () => null,
          ),
        );
        return;
      }
      final engine = _pickEngine(engines);
      final languages = await _loadLanguages(engine);
      if (!_isCurrentEngines(request)) return;
      final changed = engine.id != state.engine?.id;
      if (changed) _cancelTranslation();
      final base = changed
          ? _clearedExtras(state)
                .copyWith(status: TranslateStatus.idle, result: () => null)
          : state;
      emit(
        _withLanguages(base, engine, languages).copyWith(
          enginesStatus: EnginesStatus.ready,
          engines: engines,
          engine: () => engine,
          assistEngine: () => _pickAssistEngine(engine, engines),
          error: () => null,
        ),
      );
    } on Object catch (error) {
      if (!_isCurrentEngines(request)) return;
      emit(
        state.copyWith(
          enginesStatus: EnginesStatus.failure,
          error: () => error,
        ),
      );
      return;
    }
    // Text that arrived before engines were available (share intent).
    if (state.input.trim().isNotEmpty &&
        state.result == null &&
        state.status != TranslateStatus.translating) {
      unawaited(translate());
    }
  }

  /// Keeps current languages when possible via `LanguageMatcher`.
  Future<void> selectEngine(TranslationEngine engine) async {
    if (engine.id == state.engine?.id &&
        state.enginesStatus == EnginesStatus.ready) {
      return;
    }
    final switched = await _switchEngine(engine, keepResult: false);
    if (switched && state.input.trim().isNotEmpty) await translate();
  }

  /// Switches to [engine] and reloads/re-maps languages. Returns whether the
  /// languages loaded (and this switch is still current).
  Future<bool> _switchEngine(
    TranslationEngine engine, {
    required bool keepResult,
  }) async {
    final request = ++_enginesRequest;
    _settings.setEngine(engine.id);
    if (!keepResult) {
      _debounceTimer?.cancel();
      _cancelTranslation();
    }
    var next = _clearedExtras(state).copyWith(
      engine: () => engine,
      assistEngine: () => _pickAssistEngine(engine, state.engines),
    );
    if (!keepResult) {
      next = next.copyWith(
        status: TranslateStatus.idle,
        result: () => null,
        error: () => null,
      );
    }
    emit(next);
    try {
      final languages = await _loadLanguages(engine);
      if (!_isCurrentEngines(request)) return false;
      emit(_withLanguages(state, engine, languages));
      return true;
    } on Object catch (error) {
      if (!_isCurrentEngines(request)) return false;
      emit(
        state.copyWith(
          enginesStatus: EnginesStatus.failure,
          error: () => error,
        ),
      );
      return false;
    }
  }

  bool _isCurrentEngines(int request) =>
      !isClosed && request == _enginesRequest;

  TranslationEngine _pickEngine(List<TranslationEngine> engines) {
    TranslationEngine? byId(String? id) {
      if (id == null) return null;
      for (final engine in engines) {
        if (engine.id == id) return engine;
      }
      return null;
    }

    return byId(_settings.state.engineId) ??
        byId(state.engine?.id) ??
        byId(_defaultEngineId) ??
        engines.first;
  }

  TranslationEngine? _pickAssistEngine(
    TranslationEngine engine,
    List<TranslationEngine> engines,
  ) {
    if (engine.isAi) return engine;
    final ai = engines.where((e) => e.isAi).toList();
    final configured = _settings.state.assistEngineId;
    for (final candidate in ai) {
      if (candidate.id == configured) return candidate;
    }
    return ai.isEmpty ? null : ai.first;
  }

  Future<({List<Language> sources, List<Language> targets})> _loadLanguages(
    TranslationEngine engine,
  ) async {
    // Future.wait (unlike record `.wait`) rethrows the original error.
    final lists = await Future.wait([
      _repository.getSourceLanguages(engine),
      _repository.getTargetLanguages(engine),
    ]);
    return (sources: lists[0], targets: lists[1]);
  }

  /// Applies the language lists of [engine] to [base], re-mapping the
  /// current source/target onto them.
  TranslateState _withLanguages(
    TranslateState base,
    TranslationEngine engine,
    ({List<Language> sources, List<Language> targets}) languages,
  ) {
    final sources = languages.sources;
    final targets = languages.targets;

    Language source;
    final sourceMatch = base.source.isCustom
        ? null
        : LanguageMatcher.match(base.source, sources);
    if (sourceMatch != null) {
      source = sourceMatch;
    } else if (sources.isEmpty || sources.contains(Language.auto)) {
      source = Language.auto;
    } else {
      source = sources.first;
    }

    final allowCustom = engine.supportsCustomLanguages;
    final targetMatch = base.target.isCustom && !allowCustom
        ? null
        : LanguageMatcher.match(base.target, targets, allowCustom: allowCustom);
    final target =
        targetMatch ??
        LanguageMatcher.match(_english, targets) ??
        (targets.isEmpty ? _english : targets.first);

    return base.copyWith(
      sourceLanguages: sources,
      targetLanguages: targets,
      source: source,
      target: target,
    );
  }

  // ---------------------------------------------------------------------
  // Input & languages
  // ---------------------------------------------------------------------

  void setInput(String text) {
    if (text == state.input) return;
    _debounceTimer?.cancel();
    _cancelCompare();
    if (text.trim().isEmpty) {
      _cancelTranslation();
      emit(
        _clearedExtras(state).copyWith(
          input: text,
          result: () => null,
          status: TranslateStatus.idle,
          error: () => null,
          compareEntries: const [],
          comparing: false,
        ),
      );
      return;
    }
    emit(
      _clearedExtras(state)
          .copyWith(input: text, compareEntries: const [], comparing: false),
    );
    final engine = state.engine;
    if (engine == null || state.compareMode) return;
    final instant = engine.isAi
        ? _settings.state.instantTranslateAi
        : _settings.state.instantTranslate;
    if (!instant) return;
    _debounceTimer = Timer(
      engine.isAi ? aiDebounce : debounce,
      () => unawaited(translate()),
    );
  }

  /// Replaces input and translates immediately (share intents, history).
  void setInputAndTranslate(String text) {
    setInput(text);
    unawaited(translate());
  }

  void setSource(Language language) {
    if (language == state.source || language.isCustom) return;
    _settings.setLanguages(source: language);
    if (!language.isAuto) _settings.addRecentLanguage(language);
    emit(_clearedExtras(state).copyWith(source: language));
    _retranslate();
  }

  void setTarget(Language language) {
    if (language == state.target || language.isAuto) return;
    final engine = state.engine;
    if (language.isCustom &&
        engine != null &&
        !engine.supportsCustomLanguages) {
      return;
    }
    if (!language.isCustom &&
        _smartSwappedFrom != null &&
        LanguageMatcher.normalize(language.code) == _smartSwappedFrom) {
      _smartSwapDeclined = _smartSwappedFrom;
    }
    _settings
      ..setLanguages(target: language)
      ..addRecentLanguage(language);
    emit(_clearedExtras(state).copyWith(target: language));
    _retranslate();
  }

  /// Swaps languages (detected language when auto) and moves the output
  /// into the input.
  void swap() {
    if (!state.canSwap) return;
    final Language newTarget;
    if (state.source.isAuto) {
      final detected = state.result?.detectedSource;
      if (detected == null || detected.isEmpty) return;
      final match = LanguageMatcher.match(
        Language(code: detected, name: detected),
        state.targetLanguages,
      );
      if (match == null) return;
      newTarget = match;
    } else {
      newTarget =
          LanguageMatcher.match(state.source, state.targetLanguages) ??
          state.source;
    }
    final newSource =
        LanguageMatcher.match(state.target, state.sourceLanguages) ??
        state.target;
    final output = state.output;

    _debounceTimer?.cancel();
    _cancelTranslation();
    _cancelCompare();
    _settings
      ..setLanguages(source: newSource, target: newTarget)
      ..addRecentLanguage(newSource)
      ..addRecentLanguage(newTarget);
    emit(
      _clearedExtras(state).copyWith(
        source: newSource,
        target: newTarget,
        input: output.isEmpty ? state.input : output,
        result: () => null,
        status: TranslateStatus.idle,
        error: () => null,
        compareEntries: const [],
        comparing: false,
      ),
    );
    unawaited(translate());
  }

  void setOptions(TranslationOptions options) {
    final persisted = options.copyWith(instructions: '');
    if (persisted == state.options) return;
    _settings.setOptions(persisted);
    emit(_clearedExtras(state).copyWith(options: persisted));
    if (state.isAiEngine) _retranslate();
  }

  void clear() {
    _debounceTimer?.cancel();
    _cancelTranslation();
    _cancelCompare();
    emit(
      _clearedExtras(state).copyWith(
        input: '',
        result: () => null,
        status: TranslateStatus.idle,
        error: () => null,
        compareEntries: const [],
        comparing: false,
      ),
    );
  }

  /// Re-translates right away (not debounced) when there is input.
  void _retranslate() {
    _debounceTimer?.cancel();
    if (state.input.trim().isEmpty) return;
    unawaited(translate());
  }

  // ---------------------------------------------------------------------
  // Translation
  // ---------------------------------------------------------------------

  /// Translate now (button / Ctrl+Enter). In compare mode this runs
  /// [runCompare] instead.
  ///
  /// The future completes when the translation finished, failed or was
  /// superseded.
  Future<void> translate() {
    _debounceTimer?.cancel();
    if (state.compareMode) return runCompare();
    return _translate();
  }

  Future<void> _translate({
    TranslationEngine? engine,
    TranslationOptions? options,
    bool smartSwap = true,
  }) {
    final selected = engine ?? state.engine;
    final text = state.input;
    if (selected == null || text.trim().isEmpty) return Future.value();
    _cancelTranslation();
    final id = _translationRequest;
    final done = _translationDone = Completer<void>();
    final request = TranslationRequest(
      text: text,
      source: state.source,
      target: state.target,
      options: options ?? state.options,
    );
    emit(
      _clearedExtras(state)
          .copyWith(status: TranslateStatus.translating, error: () => null),
    );

    void fail(Object error) {
      _translation = null;
      emit(
        state.copyWith(
          status: TranslateStatus.failure,
          result: () => null,
          error: () => error,
        ),
      );
      _complete(done);
    }

    final Stream<TranslationResult> stream;
    try {
      stream = _repository.translate(selected, request);
    } on Object catch (error) {
      fail(error);
      return done.future;
    }
    _translation = stream.listen(
      (result) {
        if (!_isCurrentTranslation(id)) return;
        _onResult(selected, request, result, smartSwap: smartSwap);
      },
      onError: (Object error) {
        if (_isCurrentTranslation(id)) fail(error);
      },
      onDone: () {
        if (!_isCurrentTranslation(id)) return;
        _translation = null;
        if (state.status == TranslateStatus.translating) {
          emit(
            state.copyWith(
              status: state.result == null
                  ? TranslateStatus.idle
                  : TranslateStatus.success,
            ),
          );
        }
        _complete(done);
      },
      cancelOnError: true,
    );
    return done.future;
  }

  void _onResult(
    TranslationEngine engine,
    TranslationRequest request,
    TranslationResult result, {
    required bool smartSwap,
  }) {
    if (!result.isComplete) {
      emit(state.copyWith(result: () => result));
      return;
    }
    final swapTo = smartSwap ? _smartSwapTarget(request, result) : null;
    if (swapTo != null) {
      // Hand the caller's future over to the re-translation.
      final done = _translationDone;
      _translationDone = null;
      _smartSwappedFrom = LanguageMatcher.normalize(request.target.code);
      _settings
        ..setLanguages(target: swapTo)
        ..addRecentLanguage(swapTo);
      emit(state.copyWith(target: swapTo, result: () => null));
      final next = _translate(
        engine: engine,
        options: request.options,
        smartSwap: false,
      );
      if (done != null && !done.isCompleted) done.complete(next);
      return;
    }
    emit(state.copyWith(result: () => result, status: TranslateStatus.success));
    _record(request, result, engineId: engine.id, engineName: engine.name);
  }

  /// The language to switch the target to when the detected source equals
  /// the target, else null.
  Language? _smartSwapTarget(
    TranslationRequest request,
    TranslationResult result,
  ) {
    final detected = result.detectedSource;
    if (!request.source.isAuto ||
        request.target.isCustom ||
        detected == null ||
        detected.isEmpty) {
      return null;
    }
    final detectedCode = LanguageMatcher.normalize(detected);
    if (detectedCode != LanguageMatcher.normalize(request.target.code) ||
        detectedCode == _smartSwapDeclined) {
      return null;
    }
    final targets = state.targetLanguages;
    bool differs(Language language) =>
        !language.isAuto &&
        !language.isCustom &&
        LanguageMatcher.normalize(language.code) != detectedCode;
    Language? available(Language language) =>
        targets.isEmpty ? language : LanguageMatcher.match(language, targets);

    for (final recent in _settings.state.recentLanguages) {
      if (!differs(recent)) continue;
      final match = available(recent);
      if (match != null && differs(match)) return match;
    }
    if (_primarySubtag(detectedCode) != 'en') {
      final english = available(_english);
      if (english != null && differs(english)) return english;
    }
    for (final language in targets) {
      if (differs(language)) return language;
    }
    return null;
  }

  static String _primarySubtag(String code) =>
      code.split(RegExp('[-_]')).first.toLowerCase();

  bool _isCurrentTranslation(int id) => !isClosed && id == _translationRequest;

  void _cancelTranslation() {
    _translationRequest++;
    unawaited(_translation?.cancel());
    _translation = null;
    final done = _translationDone;
    _translationDone = null;
    if (done != null) _complete(done);
  }

  /// Adds the translation to history when enabled. The history repository
  /// replaces the newest entry when text+target+engine match, so this also
  /// serves to update an entry after alternatives/variations.
  void _record(
    TranslationRequest request,
    TranslationResult result, {
    required String engineId,
    required String engineName,
  }) {
    if (!_settings.state.saveHistory || result.text.trim().isEmpty) return;
    final now = DateTime.now();
    final entry = HistoryEntry(
      id: now.microsecondsSinceEpoch.toString(),
      text: request.text,
      translation: result.text,
      source: request.source,
      target: request.target,
      engineId: engineId,
      engineName: engineName,
      createdAt: now,
      detectedSource: result.detectedSource,
    );
    unawaited(_history.add(entry).catchError(addError));
  }

  /// Records the current state's result (after edits / picking from
  /// compare).
  void _recordCurrent() {
    final result = state.result;
    if (result == null) return;
    _record(
      TranslationRequest(
        text: state.input,
        source: state.source,
        target: state.target,
        options: state.options,
      ),
      result,
      engineId: result.engineId,
      engineName: result.engineName,
    );
  }

  /// Re-translates with the suggestion's instruction as a one-off. When the
  /// main engine is a Mozhi engine the assist (AI) engine is used.
  Future<void> applySuggestion(RefinementSuggestion suggestion) {
    _debounceTimer?.cancel();
    final engine = state.isAiEngine
        ? state.engine
        : state.assistEngine ?? state.engine;
    return _translate(
      engine: engine,
      options: state.options.copyWith(instructions: suggestion.instruction),
    );
  }

  /// Replaces the output with an alternative (and records it in history).
  void useAlternative(String text) {
    final result = state.result;
    if (result == null || text == result.text) return;
    _invalidateExtra(_Extra.insights);
    _invalidateExtra(_Extra.explain);
    emit(
      state.copyWith(
        result: () => result.copyWith(text: text, isComplete: true),
        status: TranslateStatus.success,
        insightsStatus: ExtraStatus.idle,
        insights: const [],
        explainStatus: ExtraStatus.idle,
        explanation: '',
      ),
    );
    _recordCurrent();
  }

  /// Replaces the first occurrence of `insight.targetText` in the output
  /// with [variation], and updates the insight's targetText.
  void applyVariation(WordInsight insight, String variation) {
    final result = state.result;
    if (result == null ||
        insight.targetText.isEmpty ||
        !result.text.contains(insight.targetText)) {
      return;
    }
    final text = result.text.replaceFirst(insight.targetText, variation);
    final updated = WordInsight(
      sourceText: insight.sourceText,
      targetText: variation,
      type: insight.type,
      explanation: insight.explanation,
      variations: insight.variations,
    );
    emit(
      state.copyWith(
        result: () => result.copyWith(text: text),
        insights: state.insights
            .map((item) => identical(item, insight) ? updated : item)
            .toList(),
      ),
    );
    _recordCurrent();
  }

  // ---------------------------------------------------------------------
  // Compare
  // ---------------------------------------------------------------------

  void setCompareMode({required bool enabled}) {
    if (enabled == state.compareMode) return;
    _cancelCompare();
    emit(
      state.copyWith(
        compareMode: enabled,
        compareEntries: const [],
        comparing: false,
      ),
    );
  }

  /// Runs the configured compare engines (all when none configured; AI
  /// only for custom targets) and collects their results progressively.
  Future<void> runCompare() {
    _debounceTimer?.cancel();
    final text = state.input;
    if (text.trim().isEmpty) return Future.value();
    final ids = _settings.state.compareEngineIds;
    var engines = ids.isEmpty
        ? state.engines
        : state.engines.where((e) => ids.contains(e.id)).toList();
    if (engines.isEmpty) engines = state.engines;
    if (state.target.isCustom) {
      engines = engines.where((e) => e.supportsCustomLanguages).toList();
    }
    if (engines.isEmpty) return Future.value();

    _cancelCompare();
    final id = _compareRequest;
    final done = _compareDone = Completer<void>();
    final request = TranslationRequest(
      text: text,
      source: state.source,
      target: state.target,
      options: state.options,
    );
    emit(
      state.copyWith(
        compareEntries: const [],
        comparing: true,
        error: () => null,
      ),
    );

    void finish({Object? error}) {
      _compare = null;
      emit(
        state.copyWith(
          comparing: false,
          error: error == null ? null : () => error,
        ),
      );
      _complete(done);
    }

    final Stream<CompareEntry> stream;
    try {
      stream = _repository.compare(engines, request);
    } on Object catch (error) {
      finish(error: error);
      return done.future;
    }
    _compare = stream.listen(
      (entry) {
        if (!_isCurrentCompare(id)) return;
        emit(state.copyWith(compareEntries: [...state.compareEntries, entry]));
      },
      onError: (Object error) {
        if (_isCurrentCompare(id)) finish(error: error);
      },
      onDone: () {
        if (_isCurrentCompare(id)) finish();
      },
      cancelOnError: true,
    );
    return done.future;
  }

  /// Selects [entry] as the main result (and its engine).
  void useCompareEntry(CompareEntry entry) {
    final result = entry.result;
    if (result == null) return;
    TranslationEngine? engine;
    for (final candidate in state.engines) {
      if (candidate.id == entry.id) engine = candidate;
    }
    if (engine == null) return;
    _debounceTimer?.cancel();
    _cancelCompare();
    _cancelTranslation();
    emit(
      _clearedExtras(state).copyWith(
        compareMode: false,
        compareEntries: const [],
        comparing: false,
        result: () => result,
        status: TranslateStatus.success,
        error: () => null,
      ),
    );
    _recordCurrent();
    if (engine.id != state.engine?.id) {
      unawaited(_switchEngine(engine, keepResult: true));
    }
  }

  bool _isCurrentCompare(int id) => !isClosed && id == _compareRequest;

  void _cancelCompare() {
    _compareRequest++;
    unawaited(_compare?.cancel());
    _compare = null;
    final done = _compareDone;
    _compareDone = null;
    if (done != null) _complete(done);
  }

  // ---------------------------------------------------------------------
  // Extras (AI)
  // ---------------------------------------------------------------------

  Future<void> loadAlternatives({String? span}) => _loadExtra(
    _Extra.alternatives,
    loading: (s) => s.copyWith(
      alternativesStatus: ExtraStatus.loading,
      alternativesSpan: () => span,
    ),
    fetch: (engine, request, output) =>
        _repository.getAlternatives(engine, request, output, span: span),
    ready: (s, value) => s.copyWith(
      alternativesStatus: ExtraStatus.ready,
      alternatives: () => value,
    ),
    failed: (s) => s.copyWith(alternativesStatus: ExtraStatus.failure),
  );

  Future<void> loadInsights() => _loadExtra(
    _Extra.insights,
    loading: (s) => s.copyWith(insightsStatus: ExtraStatus.loading),
    fetch: _repository.getInsights,
    ready: (s, value) =>
        s.copyWith(insightsStatus: ExtraStatus.ready, insights: value),
    failed: (s) => s.copyWith(insightsStatus: ExtraStatus.failure),
  );

  Future<void> loadSuggestions() => _loadExtra(
    _Extra.suggestions,
    loading: (s) => s.copyWith(suggestionsStatus: ExtraStatus.loading),
    fetch: _repository.getSuggestions,
    ready: (s, value) => s.copyWith(
      suggestionsStatus: ExtraStatus.ready,
      suggestions: _mergeSuggestions(value),
    ),
    failed: (s) => s.copyWith(suggestionsStatus: ExtraStatus.failure),
  );

  /// [RefinementSuggestion.defaults] followed by fetched suggestions whose
  /// label and instruction are new (case-insensitive).
  static List<RefinementSuggestion> _mergeSuggestions(
    List<RefinementSuggestion> fetched,
  ) {
    final merged = [...RefinementSuggestion.defaults];
    final labels = {for (final s in merged) s.label.trim().toLowerCase()};
    final instructions = {
      for (final s in merged) s.instruction.trim().toLowerCase(),
    };
    for (final suggestion in fetched) {
      final label = suggestion.label.trim().toLowerCase();
      final instruction = suggestion.instruction.trim().toLowerCase();
      if (label.isEmpty || instruction.isEmpty) continue;
      if (labels.contains(label) || instructions.contains(instruction)) {
        continue;
      }
      labels.add(label);
      instructions.add(instruction);
      merged.add(suggestion);
    }
    return merged;
  }

  /// Streams an explanation of the translation (Markdown deltas are
  /// appended to `explanation`).
  Future<void> explain({String? question}) {
    final engine = state.assistEngine;
    final output = _completedOutput;
    if (engine == null || output == null) return Future.value();
    _cancelExplanation();
    final token = _invalidateExtra(_Extra.explain);
    final done = _explanationDone = Completer<void>();
    emit(
      state.copyWith(
        explainStatus: ExtraStatus.loading,
        explanation: '',
        extraError: () => null,
      ),
    );

    void fail(Object error) {
      _explanation = null;
      emit(
        state.copyWith(
          explainStatus: ExtraStatus.failure,
          extraError: () => error,
        ),
      );
      _complete(done);
    }

    final Stream<String> stream;
    try {
      stream = _repository.explain(
        engine,
        _extrasRequest(),
        output,
        question: question,
      );
    } on Object catch (error) {
      fail(error);
      return done.future;
    }
    _explanation = stream.listen(
      (chunk) {
        if (!_isCurrentExtra(_Extra.explain, token)) return;
        emit(state.copyWith(explanation: state.explanation + chunk));
      },
      onError: (Object error) {
        if (_isCurrentExtra(_Extra.explain, token)) fail(error);
      },
      onDone: () {
        if (!_isCurrentExtra(_Extra.explain, token)) return;
        _explanation = null;
        emit(state.copyWith(explainStatus: ExtraStatus.ready));
        _complete(done);
      },
      cancelOnError: true,
    );
    return done.future;
  }

  /// Dictionary for the (short) input.
  Future<void> lookUp() async {
    final engine = state.assistEngine;
    final word = state.input.trim();
    if (engine == null || word.isEmpty) return;
    final token = _invalidateExtra(_Extra.dictionary);
    emit(
      state.copyWith(
        dictionaryStatus: ExtraStatus.loading,
        extraError: () => null,
      ),
    );
    try {
      final entry = await _repository.lookUp(
        engine,
        word,
        source: _effectiveSource(),
        target: state.target,
      );
      if (!_isCurrentExtra(_Extra.dictionary, token)) return;
      emit(
        state.copyWith(
          dictionaryStatus: ExtraStatus.ready,
          dictionary: () => entry,
        ),
      );
    } on Object catch (error) {
      if (!_isCurrentExtra(_Extra.dictionary, token)) return;
      emit(
        state.copyWith(
          dictionaryStatus: ExtraStatus.failure,
          extraError: () => error,
        ),
      );
    }
  }

  void clearExtras() => emit(_clearedExtras(state));

  Future<void> _loadExtra<T>(
    _Extra extra, {
    required TranslateState Function(TranslateState state) loading,
    required Future<T> Function(
      TranslationEngine engine,
      TranslationRequest request,
      String translation,
    )
    fetch,
    required TranslateState Function(TranslateState state, T value) ready,
    required TranslateState Function(TranslateState state) failed,
  }) async {
    final engine = state.assistEngine;
    final output = _completedOutput;
    if (engine == null || output == null) return;
    final token = _invalidateExtra(extra);
    emit(loading(state).copyWith(extraError: () => null));
    try {
      final value = await fetch(engine, _extrasRequest(), output);
      if (!_isCurrentExtra(extra, token)) return;
      emit(ready(state, value));
    } on Object catch (error) {
      if (!_isCurrentExtra(extra, token)) return;
      emit(failed(state).copyWith(extraError: () => error));
    }
  }

  /// The finished output extras can work on, else null.
  String? get _completedOutput {
    final result = state.result;
    if (result == null || !result.isComplete) return null;
    if (result.text.trim().isEmpty || state.input.trim().isEmpty) return null;
    return result.text;
  }

  TranslationRequest _extrasRequest() => TranslationRequest(
    text: state.input,
    source: _effectiveSource(),
    target: state.target,
    options: state.options,
  );

  /// The selected source, or the detected one (mapped onto the source list
  /// when possible) when the source is auto.
  Language _effectiveSource() {
    final source = state.source;
    final detected = state.result?.detectedSource;
    if (!source.isAuto || detected == null || detected.isEmpty) return source;
    final wanted = Language(code: detected, name: detected);
    return LanguageMatcher.match(wanted, state.sourceLanguages) ?? wanted;
  }

  /// Invalidates in-flight requests for [extra]; returns the new token.
  int _invalidateExtra(_Extra extra) {
    if (extra == _Extra.explain) _cancelExplanation();
    return _extraRequests[extra] = (_extraRequests[extra] ?? 0) + 1;
  }

  bool _isCurrentExtra(_Extra extra, int token) =>
      !isClosed && _extraRequests[extra] == token;

  /// Invalidates all in-flight extras and returns [base] with every extra
  /// reset.
  TranslateState _clearedExtras(TranslateState base) {
    _Extra.values.forEach(_invalidateExtra);
    return base.copyWith(
      alternativesStatus: ExtraStatus.idle,
      alternatives: () => null,
      alternativesSpan: () => null,
      insightsStatus: ExtraStatus.idle,
      insights: const [],
      suggestionsStatus: ExtraStatus.idle,
      suggestions: RefinementSuggestion.defaults,
      explainStatus: ExtraStatus.idle,
      explanation: '',
      dictionaryStatus: ExtraStatus.idle,
      dictionary: () => null,
      extraError: () => null,
    );
  }

  void _cancelExplanation() {
    unawaited(_explanation?.cancel());
    _explanation = null;
    final done = _explanationDone;
    _explanationDone = null;
    if (done != null) _complete(done);
  }

  static void _complete(Completer<void> completer) {
    if (!completer.isCompleted) completer.complete();
  }

  @override
  Future<void> close() {
    _debounceTimer?.cancel();
    _enginesRequest++;
    _cancelTranslation();
    _cancelCompare();
    _cancelExplanation();
    return super.close();
  }
}
