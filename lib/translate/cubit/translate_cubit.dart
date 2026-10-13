import 'dart:async';
import 'dart:math' as math;
import 'dart:ui' show PlatformDispatcher;

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

typedef _Languages = ({List<Language> sources, List<Language> targets});

/// Drives the translate screen.
///
/// * Reads initial engine/languages/options from `settings` and writes
///   selection changes back (`setEngine`, `setLanguages`,
///   `addRecentLanguage`, `setOptions`).
/// * Typing ([setInput]) debounces and auto-translates when
///   `instantTranslate` (Mozhi) / `instantTranslateAi` (AI) is on; any new
///   translation cancels the in-flight one (stream subscription cancel).
/// * Text from outside the app ([setExternalInput]) is length-capped and
///   only auto-translated when that costs nothing (see there).
/// * Completed translations are added to `history` when `saveHistory`.
///   Consecutive instant translations of the same, growing text update one
///   entry instead of adding one per typing pause.
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
    DateTime Function()? clock,
    List<String> Function()? deviceLanguages,
  }) : _settings = settings,
       _clock = clock ?? DateTime.now,
       _deviceLanguages = deviceLanguages ?? _platformLanguages,
       super(
         TranslateState(
           source: settings.state.source,
           target: settings.state.target,
           options: settings.state.options,
         ),
       );

  /// Longest input kept (typed or pasted); longer text is cut and
  /// `inputTruncated` is set.
  static const maxInputLength = 20000;

  /// Longest text accepted from outside the app ([setExternalInput]).
  static const maxExternalInputLength = 5000;

  /// The same external text arriving again within this window is ignored.
  static const externalRepeatWindow = Duration(seconds: 2);

  /// An instant (debounced) translation recorded in history is replaced by
  /// the next recording of an edit of the same text within this window.
  static const historyMergeWindow = Duration(seconds: 30);

  /// Longest model-generated refinement instruction passed on.
  static const maxRefinementLength = 200;

  /// Marks a model-generated suggestion instruction as a lower-trust
  /// refinement preference rather than a user instruction.
  static const refinementPrefix =
      'Refinement preference (from a suggestion chip):';

  static const _english = Language(code: 'en', name: 'English');
  static const _defaultEngineId = 'mozhi:google';

  /// Smart-swap targets tried after the user's own languages.
  static const _popularTargets = [
    'es',
    'fr',
    'de',
    'zh',
    'ja',
    'pt',
    'ru',
    'it',
    'ko',
    'ar',
    'hi',
  ];

  final TranslationRepository _repository;
  final SettingsCubit _settings;
  final HistoryCubit _history;
  final DateTime Function() _clock;
  final List<String> Function() _deviceLanguages;

  /// Instant-translate delay for Mozhi engines.
  final Duration debounce;

  /// Instant-translate delay for AI engines.
  final Duration aiDebounce;

  Timer? _debounceTimer;

  /// Engine-list loads ([loadEngines]).
  int _enginesRequest = 0;

  /// Language loads for the selected engine (the second half of
  /// [loadEngines], and every engine switch).
  int _languagesRequest = 0;

  /// Engine switches started (to notice a pick during an engine-list load).
  int _switches = 0;

  /// An engine-list fetch is in flight.
  bool _listPending = false;

  StreamSubscription<TranslationResult>? _translation;
  Completer<void>? _translationDone;
  int _translationRequest = 0;

  StreamSubscription<CompareEntry>? _compare;
  Completer<void>? _compareDone;
  int _compareRequest = 0;

  StreamSubscription<String>? _explanation;
  Completer<void>? _explanationDone;
  final _extraRequests = <_Extra, int>{};

  /// Normalised code of the target the user picked explicitly; no smart
  /// swaps away from it this session.
  String? _smartSwapDeclined;

  /// The input came from outside the app and has not been translated yet.
  bool _externalPending = false;

  /// The last external text and when it arrived (repeat filter).
  ({String text, DateTime at})? _lastExternal;

  /// The last history entry recorded by an instant translation; the next
  /// recording of an edit of its text replaces it.
  ({String id, String text, Language target, String engineId, DateTime at})?
  _provisionalEntry;
  int _lastEntryMicros = 0;

  static List<String> _platformLanguages() => [
    for (final locale in PlatformDispatcher.instance.locales)
      locale.toLanguageTag(),
  ];

  // ---------------------------------------------------------------------
  // Engines
  // ---------------------------------------------------------------------

  /// Loads engines + language lists for the selected engine. Call on start
  /// and whenever instances/providers change ([refresh] forces refetch).
  ///
  /// When the preferred engine's languages fail to load, the next candidate
  /// is used (the current engine, the default, the first engine). When all
  /// fail the engine list is still emitted (status failure) so another
  /// engine can be picked.
  Future<void> loadEngines({bool refresh = false}) async {
    final request = ++_enginesRequest;
    final switches = _switches;
    _listPending = true;
    emit(state.copyWith(enginesStatus: EnginesStatus.loading));
    final List<TranslationEngine> engines;
    try {
      engines = await _repository.getEngines(refresh: refresh);
    } on Object catch (error) {
      if (!_isCurrentEngines(request)) return;
      _listPending = false;
      emit(
        state.copyWith(
          enginesStatus: EnginesStatus.failure,
          error: () => error,
        ),
      );
      return;
    }
    if (!_isCurrentEngines(request)) return;
    _listPending = false;
    if (engines.isEmpty) {
      _languagesRequest++;
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

    // An engine the user picked while the list was loading wins.
    final picked = _switches != switches ? state.engine : null;
    final languagesRequest = ++_languagesRequest;
    final loaded = await _loadFirstUsable(
      _engineCandidates(engines, preferred: picked),
      isCurrent: () =>
          _isCurrentEngines(request) && languagesRequest == _languagesRequest,
    );
    if (!_isCurrentEngines(request)) return;
    if (languagesRequest != _languagesRequest) {
      // A switch started meanwhile and maps its own languages (and sets the
      // status): only apply the refreshed list.
      final current = state.engine;
      emit(
        state.copyWith(
          engines: engines,
          assistEngine: current == null
              ? null
              : () => _pickAssistEngine(current, engines),
        ),
      );
      return;
    }

    final engine = loaded.engine;
    final changed = engine.id != state.engine?.id;
    if (changed) _cancelTranslation();
    final base = changed
        ? _clearedExtras(state)
              .copyWith(status: TranslateStatus.idle, result: () => null)
        : state;
    final languages = loaded.languages;
    if (languages == null) {
      emit(
        base.copyWith(
          enginesStatus: EnginesStatus.failure,
          engines: engines,
          engine: () => engine,
          assistEngine: () => _pickAssistEngine(engine, engines),
          error: () => loaded.error,
        ),
      );
      return;
    }
    if (picked?.id == engine.id && _settings.state.engineId != engine.id) {
      _settings.setEngine(engine.id);
    }
    emit(
      _withLanguages(base, engine, languages).copyWith(
        enginesStatus: EnginesStatus.ready,
        engines: engines,
        engine: () => engine,
        assistEngine: () => _pickAssistEngine(engine, engines),
        error: () => null,
      ),
    );

    // Text that arrived before engines were available (share intent).
    if (state.input.trim().isNotEmpty &&
        state.result == null &&
        state.status != TranslateStatus.translating &&
        !state.compareMode &&
        (!_externalPending || _mayAutoTranslateExternal)) {
      unawaited(_translate());
    }
  }

  /// Keeps current languages when possible via `LanguageMatcher`. The
  /// choice is saved once the engine's languages loaded.
  Future<void> selectEngine(TranslationEngine engine) async {
    if (engine.id == state.engine?.id &&
        state.enginesStatus == EnginesStatus.ready) {
      return;
    }
    final switched = await _switchEngine(engine, keepResult: false);
    // Compare results do not depend on the main engine: no re-compare.
    if (switched && state.input.trim().isNotEmpty && !state.compareMode) {
      await _translate();
    }
  }

  /// Switches to [engine] and reloads/re-maps languages. Returns whether the
  /// languages loaded (and this switch is still current).
  Future<bool> _switchEngine(
    TranslationEngine engine, {
    required bool keepResult,
  }) async {
    final request = ++_languagesRequest;
    _switches++;
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
      if (!_isCurrentLanguages(request)) return false;
      _settings.setEngine(engine.id);
      final failed = state.enginesStatus == EnginesStatus.failure;
      emit(
        _withLanguages(state, engine, languages).copyWith(
          enginesStatus: _listPending
              ? EnginesStatus.loading
              : EnginesStatus.ready,
          error: failed ? () => null : null,
        ),
      );
      return true;
    } on Object catch (error) {
      if (!_isCurrentLanguages(request)) return false;
      emit(
        state.copyWith(
          enginesStatus: _listPending
              ? EnginesStatus.loading
              : EnginesStatus.failure,
          error: () => error,
        ),
      );
      return false;
    }
  }

  bool _isCurrentEngines(int request) =>
      !isClosed && request == _enginesRequest;

  bool _isCurrentLanguages(int request) =>
      !isClosed && request == _languagesRequest;

  /// Engines to try, best first: [preferred], the saved engine, the current
  /// one, the default, then the first engine.
  List<TranslationEngine> _engineCandidates(
    List<TranslationEngine> engines, {
    TranslationEngine? preferred,
  }) {
    TranslationEngine? byId(String? id) {
      if (id == null) return null;
      for (final engine in engines) {
        if (engine.id == id) return engine;
      }
      return null;
    }

    final candidates = <TranslationEngine>[];
    for (final engine in [
      byId(preferred?.id),
      byId(_settings.state.engineId),
      byId(state.engine?.id),
      byId(_defaultEngineId),
      engines.first,
    ]) {
      if (engine != null && candidates.every((e) => e.id != engine.id)) {
        candidates.add(engine);
      }
    }
    return candidates;
  }

  /// Loads the languages of the first candidate that works. Failures are
  /// reported through [addError]; when every candidate fails (or the load
  /// is no longer [isCurrent]), the first one is returned with the first
  /// error and no languages.
  Future<({TranslationEngine engine, _Languages? languages, Object? error})>
  _loadFirstUsable(
    List<TranslationEngine> candidates, {
    required bool Function() isCurrent,
  }) async {
    Object? firstError;
    for (final engine in candidates) {
      try {
        return (
          engine: engine,
          languages: await _loadLanguages(engine),
          error: null,
        );
      } on Object catch (error, stackTrace) {
        firstError ??= error;
        if (!isCurrent()) break;
        addError(error, stackTrace);
      }
    }
    return (engine: candidates.first, languages: null, error: firstError);
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

  Future<_Languages> _loadLanguages(TranslationEngine engine) async {
    // Future.wait (unlike record `.wait`) rethrows the original error.
    final lists = await Future.wait([
      _repository.getSourceLanguages(engine),
      _repository.getTargetLanguages(engine),
    ]);
    return (sources: lists[0], targets: lists[1]);
  }

  /// Applies the language lists of [engine] to [base]. The user's chosen
  /// languages (settings) are re-mapped first, so a language an intermediate
  /// engine lacked comes back; then the current ones; then auto/English.
  TranslateState _withLanguages(
    TranslateState base,
    TranslationEngine engine,
    _Languages languages,
  ) {
    final sources = languages.sources;
    final targets = languages.targets;
    final allowCustom = engine.supportsCustomLanguages;
    final saved = _settings.state;

    Language? matchSource(Language language) =>
        language.isCustom ? null : LanguageMatcher.match(language, sources);
    Language? matchTarget(Language language) =>
        language.isAuto || (language.isCustom && !allowCustom)
        ? null
        : LanguageMatcher.match(language, targets, allowCustom: allowCustom);

    final source =
        matchSource(saved.source) ??
        matchSource(base.source) ??
        (sources.isEmpty || sources.contains(Language.auto)
            ? Language.auto
            : sources.first);
    final target =
        matchTarget(saved.target) ??
        matchTarget(base.target) ??
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

  /// The user typed or pasted [text] (cut to [maxInputLength]).
  void setInput(String text) {
    _externalPending = false;
    _applyInput(text, maxLength: maxInputLength, instant: true);
  }

  /// Replaces input and translates immediately (history, user actions).
  ///
  /// With [external] (share intents, PROCESS_TEXT, deep links, clipboard
  /// monitors) this is [setExternalInput], which may not translate.
  void setInputAndTranslate(String text, {bool external = false}) {
    if (external) return setExternalInput(text);
    setInput(text);
    unawaited(translate());
  }

  /// Puts text that came from outside the app into the input.
  ///
  /// * The text is cut to [maxExternalInputLength] (`inputTruncated`).
  /// * The same text arriving again within [externalRepeatWindow] is
  ///   ignored.
  /// * [source] and [target] (e.g. from a link) are applied first, as by
  ///   [setSource]/[setTarget] but without re-translating the old input.
  /// * It is translated right away only when that costs nothing: Mozhi (and
  ///   other non-AI) engines, or AI engines when `instantTranslateAi` is on.
  ///   Compare mode never starts on its own. Otherwise the user presses
  ///   Translate.
  void setExternalInput(String text, {Language? source, Language? target}) {
    final now = _clock();
    final last = _lastExternal;
    if (last != null &&
        last.text == text &&
        now.difference(last.at).abs() < externalRepeatWindow) {
      return;
    }
    _lastExternal = (text: text, at: now);
    if (source != null && _applySource(source)) {
      emit(_clearedExtras(state).copyWith(source: source));
    }
    if (target != null && _applyTarget(target)) {
      emit(_clearedExtras(state).copyWith(target: target));
    }
    _applyInput(text, maxLength: maxExternalInputLength, instant: false);
    if (state.input.trim().isEmpty) return;
    _externalPending = true;
    if (_mayAutoTranslateExternal) unawaited(_translate());
  }

  /// Whether external input may be translated without a user action.
  bool get _mayAutoTranslateExternal {
    final engine = state.engine;
    if (engine == null || state.compareMode) return false;
    return !engine.isAi || _settings.state.instantTranslateAi;
  }

  void _applyInput(
    String raw, {
    required int maxLength,
    required bool instant,
  }) {
    final truncated = raw.length > maxLength;
    final text = truncated ? _truncate(raw, maxLength) : raw;
    if (text == state.input) {
      if (truncated != state.inputTruncated) {
        emit(state.copyWith(inputTruncated: truncated));
      }
      return;
    }
    _debounceTimer?.cancel();
    _cancelCompare();
    if (text.trim().isEmpty) {
      _cancelTranslation();
      emit(
        _clearedExtras(state).copyWith(
          input: text,
          inputTruncated: truncated,
          result: () => null,
          status: TranslateStatus.idle,
          error: () => null,
          compareEntries: const [],
          comparing: false,
        ),
      );
      return;
    }
    final previous = state;
    emit(
      _clearedExtras(state).copyWith(
        input: text,
        inputTruncated: truncated,
        compareEntries: const [],
        comparing: false,
        // The kept result belongs to the previous text.
        resultInput: previous.result != null && previous.resultInput == null
            ? () => previous.input
            : null,
      ),
    );
    final engine = state.engine;
    if (!instant || engine == null || state.compareMode) return;
    final enabled = engine.isAi
        ? _settings.state.instantTranslateAi
        : _settings.state.instantTranslate;
    if (!enabled) return;
    _debounceTimer = Timer(
      engine.isAi ? aiDebounce : debounce,
      () => unawaited(_translate(auto: true)),
    );
  }

  /// [text] cut to [length] UTF-16 units without splitting a surrogate pair.
  static String _truncate(String text, int length) {
    var end = length;
    final last = text.codeUnitAt(end - 1);
    if (last >= 0xD800 && last <= 0xDBFF) end--;
    return text.substring(0, end);
  }

  void setSource(Language language) {
    if (!_applySource(language)) return;
    emit(_clearedExtras(state).copyWith(source: language));
    _retranslate();
  }

  void setTarget(Language language) {
    if (!_applyTarget(language)) return;
    emit(_clearedExtras(state).copyWith(target: language));
    _retranslate();
  }

  /// Validates and persists a source pick; returns whether it applies.
  bool _applySource(Language language) {
    if (language == state.source || language.isCustom) return false;
    _settings.setLanguages(source: language);
    if (!language.isAuto) _settings.addRecentLanguage(language);
    return true;
  }

  /// Validates and persists a target pick; returns whether it applies.
  bool _applyTarget(Language language) {
    if (language == state.target || language.isAuto) return false;
    final engine = state.engine;
    if (language.isCustom &&
        engine != null &&
        !engine.supportsCustomLanguages) {
      return false;
    }
    // An explicit pick declines smart swaps away from it this session.
    if (!language.isCustom) {
      _smartSwapDeclined = LanguageMatcher.normalize(language.code);
    }
    _settings
      ..setLanguages(target: language)
      ..addRecentLanguage(language);
    return true;
  }

  /// Swaps languages (detected language when auto). The output moves into
  /// the input only when it is the finished translation of the current
  /// input; otherwise the input is kept and only the languages swap.
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
    final result = state.result;
    final current =
        result != null &&
        result.isComplete &&
        !state.isResultStale &&
        state.status != TranslateStatus.translating;
    final output = current ? result.text : '';

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
        input: output.trim().isEmpty ? state.input : output,
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
    _externalPending = false;
    emit(
      _clearedExtras(state).copyWith(
        input: '',
        inputTruncated: false,
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

  /// [auto] marks a debounced instant translation (its history entry is
  /// provisional). [text] defaults to the input.
  Future<void> _translate({
    TranslationEngine? engine,
    TranslationOptions? options,
    String? text,
    bool smartSwap = true,
    bool auto = false,
  }) {
    final selected = engine ?? state.engine;
    final input = text ?? state.input;
    if (selected == null || input.trim().isEmpty) return Future.value();
    _cancelTranslation();
    _externalPending = false;
    final id = _translationRequest;
    final done = _translationDone = Completer<void>();
    final request = TranslationRequest(
      text: input,
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
        _onResult(selected, request, result, smartSwap: smartSwap, auto: auto);
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
    required bool auto,
  }) {
    if (!result.isComplete) {
      emit(
        state.copyWith(result: () => result, resultInput: () => request.text),
      );
      return;
    }
    final swapTo = smartSwap ? _smartSwapTarget(request, result) : null;
    if (swapTo != null) {
      // Hand the caller's future over to the re-translation.
      final done = _translationDone;
      _translationDone = null;
      _settings
        ..setLanguages(target: swapTo)
        ..addRecentLanguage(swapTo);
      emit(state.copyWith(target: swapTo, result: () => null));
      final next = _translate(
        engine: engine,
        options: request.options,
        text: request.text,
        smartSwap: false,
        auto: auto,
      );
      if (done != null && !done.isCompleted) done.complete(next);
      return;
    }
    emit(
      state.copyWith(
        result: () => result,
        resultInput: () => request.text,
        status: TranslateStatus.success,
      ),
    );
    _record(
      request,
      result,
      engineId: engine.id,
      engineName: engine.name,
      auto: auto,
    );
  }

  /// The language to switch the target to when the detected source equals
  /// the target, else null.
  ///
  /// Candidates: recent, then pinned languages, the device languages,
  /// English (for non-English text), then a few widely used languages.
  /// Never an arbitrary list entry.
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
    Language? listed(String code) => targets.isEmpty
        ? null
        : LanguageMatcher.match(Language(code: code, name: code), targets);

    final settings = _settings.state;
    for (final language in [
      ...settings.recentLanguages,
      ...settings.pinnedLanguages,
    ]) {
      if (!differs(language)) continue;
      final match = available(language);
      if (match != null && differs(match)) return match;
    }
    for (final code in _deviceLanguages()) {
      final match = listed(code);
      if (match != null && differs(match)) return match;
    }
    if (_primarySubtag(detectedCode) != 'en') {
      final english = available(_english);
      if (english != null && differs(english)) return english;
    }
    for (final code in _popularTargets) {
      final match = listed(code);
      if (match != null && differs(match)) return match;
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
  ///
  /// An entry recorded by an instant translation ([auto]) is provisional:
  /// the next recording of an edit of its text (same engine and target,
  /// within [historyMergeWindow]) reuses its id and so replaces it.
  void _record(
    TranslationRequest request,
    TranslationResult result, {
    required String engineId,
    required String engineName,
    bool auto = false,
  }) {
    if (!_settings.state.saveHistory || result.text.trim().isEmpty) return;
    final now = _clock();
    final previous = _provisionalEntry;
    final merge =
        previous != null &&
        previous.engineId == engineId &&
        previous.target == request.target &&
        now.difference(previous.at) < historyMergeWindow &&
        _isEditOf(previous.text, request.text);
    final String id;
    if (merge) {
      id = previous.id;
    } else {
      final micros = math.max(now.microsecondsSinceEpoch, _lastEntryMicros + 1);
      _lastEntryMicros = micros;
      id = micros.toString();
    }
    _provisionalEntry = auto
        ? (
            id: id,
            text: request.text,
            target: request.target,
            engineId: engineId,
            at: now,
          )
        : null;
    final entry = HistoryEntry(
      id: id,
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

  /// Whether [next] is an edit of [previous]: one extends the other, or at
  /// least half of the shorter text is an unchanged prefix + suffix.
  static bool _isEditOf(String previous, String next) {
    final a = previous.trim();
    final b = next.trim();
    if (a.isEmpty || b.isEmpty) return false;
    if (a.startsWith(b) || b.startsWith(a)) return true;
    final shorter = math.min(a.length, b.length);
    var prefix = 0;
    while (prefix < shorter && a.codeUnitAt(prefix) == b.codeUnitAt(prefix)) {
      prefix++;
    }
    var suffix = 0;
    while (suffix < shorter - prefix &&
        a.codeUnitAt(a.length - 1 - suffix) ==
            b.codeUnitAt(b.length - 1 - suffix)) {
      suffix++;
    }
    return (prefix + suffix) * 2 >= shorter;
  }

  /// Records the current state's result (after edits / picking from
  /// compare) with the text it was made for.
  void _recordCurrent() {
    final result = state.result;
    if (result == null) return;
    _record(
      TranslationRequest(
        text: state.resultInput ?? state.input,
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
  ///
  /// Fetched suggestions are model-generated, so their instruction is
  /// passed as a lower-trust refinement (see [refinementInstruction]).
  Future<void> applySuggestion(RefinementSuggestion suggestion) {
    final instruction = refinementInstruction(suggestion);
    if (instruction.isEmpty) return Future.value();
    _debounceTimer?.cancel();
    final engine = state.isAiEngine
        ? state.engine
        : state.assistEngine ?? state.engine;
    return _translate(
      engine: engine,
      options: state.options.copyWith(instructions: instruction),
    );
  }

  /// The `TranslationOptions.instructions` sent for [suggestion].
  ///
  /// The instruction is reduced to one line of at most
  /// [maxRefinementLength] characters without control characters or `<>`.
  /// Built-in [RefinementSuggestion.defaults] are passed as they are;
  /// fetched (model-generated) ones are prefixed with [refinementPrefix].
  /// Empty when nothing is left.
  static String refinementInstruction(RefinementSuggestion suggestion) {
    final text = sanitizeRefinement(suggestion.instruction);
    if (text.isEmpty) return '';
    if (RefinementSuggestion.defaults.contains(suggestion)) return text;
    return '$refinementPrefix $text';
  }

  static final _unsafeRefinement = RegExp(
    r'[\x00-\x1F\x7F-\x9F\u2028\u2029\u200E\u200F\u202A-\u202E\u2066-\u2069]',
  );

  /// [instruction] as one line of at most [maxRefinementLength] characters,
  /// without control/bidi characters and without `<` or `>`.
  static String sanitizeRefinement(String instruction) {
    final text = instruction
        .replaceAll(_unsafeRefinement, ' ')
        .replaceAll(RegExp('[<>]'), '')
        .replaceAll(RegExp(r'\s+'), ' ')
        .trim();
    if (text.length <= maxRefinementLength) return text;
    return _truncate(text, maxRefinementLength).trimRight();
  }

  /// Uses an alternative. For whole-output alternatives it replaces the
  /// output; for span alternatives (`alternativesSpan` set) it replaces only
  /// that span, which then becomes the applied text. Records the result in
  /// history.
  void useAlternative(String text) {
    final result = state.result;
    if (result == null || text.trim().isEmpty) return;
    final span = state.alternativesSpan;
    final String output;
    int? spanStart;
    if (span == null || span.isEmpty) {
      output = text;
    } else {
      final start = _locate(
        result.text,
        span,
        offset: state.alternativesSpanStart,
      );
      if (start == null) return;
      output = result.text.replaceRange(start, start + span.length, text);
      spanStart = start;
    }
    if (output == result.text) return;
    _invalidateExtra(_Extra.insights);
    _invalidateExtra(_Extra.explain);
    emit(
      state.copyWith(
        result: () => result.copyWith(text: output, isComplete: true),
        status: TranslateStatus.success,
        insightsStatus: ExtraStatus.idle,
        insights: const [],
        explainStatus: ExtraStatus.idle,
        explanation: '',
        alternativesSpan: spanStart == null ? null : () => text,
        alternativesSpanStart: spanStart == null ? null : () => spanStart,
      ),
    );
    _recordCurrent();
  }

  /// Replaces the occurrence of `insight.targetText` the insight refers to
  /// (see [locateInsight]; [offset] is the start of the tapped highlight
  /// when known) with [variation], and updates the insight's targetText.
  void applyVariation(WordInsight insight, String variation, {int? offset}) {
    final result = state.result;
    if (result == null || insight.targetText.isEmpty) return;
    final start = locateInsight(
      result.text,
      insight,
      source: state.resultInput ?? state.input,
      offset: offset,
    );
    if (start == null) return;
    final text = result.text.replaceRange(
      start,
      start + insight.targetText.length,
      variation,
    );
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

  /// Start of the occurrence of `insight.targetText` in [text] that
  /// [insight] refers to, or null when it does not occur.
  ///
  /// [offset] wins when the target text is there. Otherwise whole-word
  /// occurrences are preferred (so `die` does not match inside `Studie`),
  /// and among them the one nearest to where `insight.sourceText` sits in
  /// [source], scaled to [text]; the first one when that is unknown.
  static int? locateInsight(
    String text,
    WordInsight insight, {
    String? source,
    int? offset,
  }) {
    double? expected;
    final sourceText = insight.sourceText;
    if (source != null && source.isNotEmpty && sourceText.isNotEmpty) {
      final at = _locate(source, sourceText);
      if (at != null) {
        expected = (at + sourceText.length / 2) / source.length * text.length;
      }
    }
    return _locate(text, insight.targetText, offset: offset, near: expected);
  }

  /// Start of [needle] in [text]: [offset] when it is there, else the
  /// whole-word occurrence (any occurrence when there is none) whose centre
  /// is nearest to [near], else the first one.
  static int? _locate(String text, String needle, {int? offset, double? near}) {
    if (needle.isEmpty) return null;
    if (offset != null &&
        offset >= 0 &&
        offset + needle.length <= text.length &&
        text.startsWith(needle, offset)) {
      return offset;
    }
    final all = <int>[];
    for (
      var i = text.indexOf(needle);
      i >= 0;
      i = text.indexOf(needle, i + 1)
    ) {
      all.add(i);
    }
    if (all.isEmpty) return null;
    final whole = [
      for (final start in all)
        if (_isWholeWord(text, start, needle.length)) start,
    ];
    final candidates = whole.isEmpty ? all : whole;
    if (near == null) return candidates.first;
    var best = candidates.first;
    var bestDistance = double.infinity;
    for (final start in candidates) {
      final distance = (start + needle.length / 2 - near).abs();
      if (distance < bestDistance) {
        best = start;
        bestDistance = distance;
      }
    }
    return best;
  }

  static final _wordChar = RegExp(r'[\p{L}\p{N}\p{M}_]', unicode: true);

  /// Whether text[start, start+length) does not continue a word on either
  /// side (only checked on sides where the match itself ends in a word
  /// character).
  static bool _isWholeWord(String text, int start, int length) {
    final end = start + length;
    bool word(String char) => _wordChar.hasMatch(char);
    if (start > 0 &&
        word(_charAt(text, start)) &&
        word(_charBefore(text, start))) {
      return false;
    }
    if (end < text.length &&
        word(_charBefore(text, end)) &&
        word(_charAt(text, end))) {
      return false;
    }
    return true;
  }

  static bool _isHigh(int unit) => unit >= 0xD800 && unit <= 0xDBFF;
  static bool _isLow(int unit) => unit >= 0xDC00 && unit <= 0xDFFF;

  /// The character (code point) starting at [index].
  static String _charAt(String text, int index) {
    final end =
        index + 1 < text.length &&
            _isHigh(text.codeUnitAt(index)) &&
            _isLow(text.codeUnitAt(index + 1))
        ? index + 2
        : index + 1;
    return text.substring(index, end);
  }

  /// The character (code point) ending at [index].
  static String _charBefore(String text, int index) {
    final start =
        index >= 2 &&
            _isLow(text.codeUnitAt(index - 1)) &&
            _isHigh(text.codeUnitAt(index - 2))
        ? index - 2
        : index - 1;
    return text.substring(start, index);
  }

  // ---------------------------------------------------------------------
  // Compare
  // ---------------------------------------------------------------------

  /// Toggles compare mode. A pending instant translation is dropped so that
  /// it cannot start a compare run nobody asked for.
  void setCompareMode({required bool enabled}) {
    if (enabled == state.compareMode) return;
    _debounceTimer?.cancel();
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
    _externalPending = false;
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
        resultInput: () => state.input,
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

  /// Loads alternatives for the whole output, or for [span] of it
  /// ([spanStart] is its offset in the output when known, e.g. from the
  /// selection).
  Future<void> loadAlternatives({String? span, int? spanStart}) => _loadExtra(
    _Extra.alternatives,
    loading: (s) => s.copyWith(
      alternativesStatus: ExtraStatus.loading,
      alternativesSpan: () => span,
      alternativesSpanStart: () => span == null ? null : spanStart,
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
  /// label and instruction are new (case-insensitive) and whose instruction
  /// survives [sanitizeRefinement].
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
      if (label.isEmpty || sanitizeRefinement(instruction).isEmpty) continue;
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

  /// The finished output of the current input extras can work on, else
  /// null (also when the output belongs to text the user since edited).
  String? get _completedOutput {
    final result = state.result;
    if (result == null || !result.isComplete || state.isResultStale) {
      return null;
    }
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
      alternativesSpanStart: () => null,
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
    _languagesRequest++;
    _cancelTranslation();
    _cancelCompare();
    _cancelExplanation();
    return super.close();
  }
}
