import 'dart:async';
import 'dart:math' as math;
import 'dart:ui' show PlatformDispatcher;

import 'package:bloc/bloc.dart';
import 'package:mozhi/history/cubit/history_cubit.dart';
import 'package:mozhi/history/models/history_entry.dart';
import 'package:mozhi/settings/cubit/settings_cubit.dart';
import 'package:mozhi/settings/models/app_settings.dart';
import 'package:mozhi/translate/cubit/translate_state.dart';
import 'package:mozhi/usage/data/usage_tracker.dart';
import 'package:translation_repository/translation_repository.dart';

export 'translate_state.dart';

/// The optional AI extras, each with its own request token so that a stale
/// response (input/result changed meanwhile) is dropped.
enum _Extra {
  alternatives,
  insights,
  suggestions,
  explain,
  dictionary,
  refinement,
  romanization,
  alignment,
  meaning,
}

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
///   AI engines stop as soon as a streaming snapshot reports that (except
///   for short input, whose detection the repository double-checks: its
///   final result decides), and a one-shot
///   [TranslateState.smartSwapNotice] tells the UI ([undoSmartSwap] goes
///   back). A detection the engine marks as uncertain never swaps.
/// * When engines (re)load and the input has no translation, it is
///   translated only when that may happen without a user action (the
///   instant translation settings; see [setExternalInput] for external
///   text).
/// * With a `usageTracker`, every finished request to a bring-your-own-key
///   provider (an engine with a `providerId`: translations, compare
///   results, refinements and AI extras) is counted once; results served
///   from the translation cache are not; tracker errors are ignored.
/// * Every [TranslationRequest] built here carries the user's recent source
///   languages (`recentSourceLanguages`, see [maxRecentSourceLanguages]).
/// * Successful translations are recorded as recent language pairs
///   (`SettingsCubit.recordPair`); [applyLanguagePair] picks one again.
/// * Quality modes ([setQualityMode]) translate with the engines chosen as
///   "Fast" / "Best" in settings without changing the normal engine.
/// * [checkMeaning] checks, on demand, whether the output means the same as
///   the input (an AI check, or a back-translation with the main engine).
/// * Extra targets ([setExtraTargets], "Also translate into…") are
///   translated with every translation of the input, each with a request
///   of its own (same engine and options; never saved in history).
///
/// The constructor does no async work: call [loadEngines] once after
/// construction (and whenever instances/providers change). It listens to
/// `settings` for changes of the quality mode engines.
class TranslateCubit extends Cubit<TranslateState> {
  new({
    required this._repository,
    required SettingsCubit settings,
    required this._history,
    this.debounce = const Duration(milliseconds: 600),
    this.aiDebounce = const Duration(milliseconds: 1200),
    DateTime Function()? clock,
    List<String> Function()? deviceLanguages,
    this._usageTracker,
  }) : _settings = settings,
       _clock = clock ?? DateTime.now,
       _deviceLanguages = deviceLanguages ?? _platformLanguages,
       _qualityIds = (settings.state.fastEngineId, settings.state.bestEngineId),
       super(
         TranslateState(
           source: settings.state.source,
           target: settings.state.target,
           options: settings.state.options,
         ),
       ) {
    _settingsSubscription = settings.stream.listen(_onSettings);
  }

  /// Most codes in [TranslationRequest.recentSourceLanguages].
  static const maxRecentSourceLanguages = 5;

  /// Longest word [lookUpWord] looks up; longer text is cut (followed words
  /// come from model output).
  static const maxDictionaryWordLength = 100;

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

  /// Most additional target languages ([setExtraTargets]).
  static const maxExtraTargets = 4;

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

  /// Counts provider usage (characters and estimated tokens); optional.
  final UsageTracker? _usageTracker;

  /// Instant-translate delay for Mozhi engines.
  // Immutable configuration passed to the constructor, not state.
  // ignore: avoid_public_fields
  final Duration debounce;

  /// Instant-translate delay for AI engines.
  // Immutable configuration passed to the constructor, not state.
  // ignore: avoid_public_fields
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

  StreamSubscription<TranslationResult>? _refinement;
  Completer<void>? _refinementDone;

  /// Extra target translations in flight, by target.
  final _extraTargetSubscriptions =
      <Language, StreamSubscription<TranslationResult>>{};

  /// Completes the future of each extra target translation in flight.
  final _extraTargetDone = <Language, Completer<void>>{};

  /// The current request token of each extra target.
  final _extraTargetTokens = <Language, int>{};
  int _extraTargetRequests = 0;

  /// The engine id and request of each extra target translation in flight
  /// (one in flight for the wanted request is never sent again).
  final _extraTargetsInFlight = <Language, (String, TranslationRequest)>{};

  /// What the last [insertExtraTranslation] replaced, for
  /// [undoInsertExtraTranslation].
  ({String input, Language source, String inserted})? _lastInsert;

  late final StreamSubscription<AppSettings> _settingsSubscription;

  /// The quality mode engine ids last seen in settings.
  (String?, String?) _qualityIds;

  /// Id of the engine in use when a quality mode was turned on: what
  /// [QualityMode.off] goes back to when `AppSettings.engineId` names no
  /// available engine.
  String? _engineBeforeQuality;

  /// Normalised code of the target the user picked explicitly; no smart
  /// swaps away from it this session.
  String? _smartSwapDeclined;

  /// Smart swaps so far (ids of [SmartSwapNotice]s).
  int _smartSwaps = 0;

  /// The last smart swap, for [undoSmartSwap] (also after the notice was
  /// consumed).
  SmartSwapNotice? _lastSmartSwap;

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
  ///
  /// The saved quality mode (`AppSettings.qualityMode`) is applied: its
  /// engine is preferred when it is configured and available, and
  /// [TranslateState.qualityMode] is that mode while its engine is the
  /// selected one ([QualityMode.off] otherwise; the saved mode is kept).
  /// [TranslateState.fastEngine] / [TranslateState.bestEngine] are resolved
  /// against the new list.
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
        _clearedExtras(_withoutExtraTranslations(state)).copyWith(
          enginesStatus: EnginesStatus.ready,
          engines: const [],
          engine: () => null,
          assistEngine: () => null,
          status: TranslateStatus.idle,
          result: () => null,
          error: () => null,
          qualityMode: QualityMode.off,
          fastEngine: () => null,
          bestEngine: () => null,
        ),
      );
      return;
    }

    // An engine the user picked while the list was loading wins; then the
    // engine of the saved quality mode.
    final picked = _switches != switches ? state.engine : null;
    final modeEngine = _engineIn(
      engines,
      _qualityEngineId(_settings.state.qualityMode),
    );
    final languagesRequest = ++_languagesRequest;
    final loaded = await _loadFirstUsable(
      _engineCandidates(engines, preferred: picked ?? modeEngine),
      isCurrent: () =>
          _isCurrentEngines(request) && languagesRequest == _languagesRequest,
    );
    if (!_isCurrentEngines(request)) return;
    final fast = _engineIn(engines, _settings.state.fastEngineId);
    final best = _engineIn(engines, _settings.state.bestEngineId);
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
          fastEngine: () => fast,
          bestEngine: () => best,
        ),
      );
      return;
    }

    final engine = loaded.engine;
    final mode = _modeOf(engine);
    final changed = engine.id != state.engine?.id;
    if (changed) _cancelTranslation();
    final base = changed
        ? _clearedExtras(_withoutExtraTranslations(state))
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
          qualityMode: mode,
          fastEngine: () => fast,
          bestEngine: () => best,
        ),
      );
      return;
    }
    // A pick made for a quality mode does not change the normal engine.
    if (picked?.id == engine.id &&
        mode == QualityMode.off &&
        _settings.state.engineId != engine.id) {
      _settings.setEngine(engine.id);
    }
    emit(
      _withLanguages(base, engine, languages).copyWith(
        enginesStatus: EnginesStatus.ready,
        engines: engines,
        engine: () => engine,
        assistEngine: () => _pickAssistEngine(engine, engines),
        error: () => null,
        qualityMode: mode,
        fastEngine: () => fast,
        bestEngine: () => best,
      ),
    );

    // Text that arrived before engines were available (share intent), or
    // whose result a new engine cleared: translated only when that may
    // happen without a user action.
    if (state.input.trim().isNotEmpty &&
        state.result == null &&
        state.status != TranslateStatus.translating &&
        _mayAutoTranslate) {
      unawaited(
        _translate(auto: !_externalPending, external: _externalPending),
      );
    }
  }

  /// Keeps current languages when possible via `LanguageMatcher`. The
  /// choice is saved once the engine's languages loaded.
  ///
  /// Choosing an engine turns quality mode off (also when [engine] is the
  /// quality mode's engine: it becomes the normal engine).
  Future<void> selectEngine(TranslationEngine engine) async {
    final leftQualityMode = _leaveQualityMode();
    if (engine.id == state.engine?.id &&
        state.enginesStatus == EnginesStatus.ready) {
      if (leftQualityMode && _settings.state.engineId != engine.id) {
        _settings.setEngine(engine.id);
      }
      return;
    }
    final switched = await _switchEngine(engine, keepResult: false);
    // Compare results do not depend on the main engine: no re-compare.
    if (switched && state.input.trim().isNotEmpty && !state.compareMode) {
      await _translate();
    }
  }

  /// Switches to [engine] and reloads/re-maps languages. Returns whether the
  /// languages loaded (and this switch is still current). With [persist]
  /// the engine is saved as the normal engine (`AppSettings.engineId`).
  Future<bool> _switchEngine(
    TranslationEngine engine, {
    required bool keepResult,
    bool persist = true,
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
      next = _withoutExtraTranslations(next).copyWith(
        status: TranslateStatus.idle,
        result: () => null,
        error: () => null,
      );
    }
    emit(next);
    try {
      final languages = await _loadLanguages(engine);
      if (!_isCurrentLanguages(request)) return false;
      if (persist) _settings.setEngine(engine.id);
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

  // ---------------------------------------------------------------------
  // Quality modes
  // ---------------------------------------------------------------------

  /// Translates with the engine chosen for [mode] (Kagi-style Fast / Best)
  /// without changing the normal engine.
  ///
  /// * [QualityMode.fast] / [QualityMode.best] select
  ///   `AppSettings.fastEngineId` / `bestEngineId` when that engine is
  ///   configured and in [TranslateState.engines]; otherwise nothing
  ///   changes (see [TranslateState.availableQualityModes]).
  ///   Turning a mode on from [QualityMode.off] remembers the engine in use
  ///   (and saves it as the normal engine when settings name none).
  /// * [QualityMode.off] returns to the normal engine: `AppSettings.engineId`
  ///   when available, else the engine in use before the mode was turned
  ///   on, else the default (or first) engine other than the mode's.
  ///
  /// The mode is saved (`SettingsCubit.setQualityMode`) unless [persist]
  /// is false (a mode a link asked for: it lasts until the app restarts or
  /// the user picks a mode or an engine). After an engine switch the input
  /// is translated again like after [selectEngine] (never in compare mode).
  /// [selectEngine] turns the mode off.
  Future<void> setQualityMode(QualityMode mode, {bool persist = true}) async {
    final TranslationEngine? engine;
    if (mode == QualityMode.off) {
      // Already on the normal engine: only the saved mode may differ.
      engine = state.qualityMode == QualityMode.off ? null : _normalEngine();
    } else {
      engine = _engineIn(state.engines, _qualityEngineId(mode));
      if (engine == null) return;
      final current = state.engine;
      if (state.qualityMode == QualityMode.off && current != null) {
        _engineBeforeQuality = current.id;
        // A fallback engine (none was ever picked) becomes the one to go
        // back to after a restart too.
        if (_settings.state.engineId == null) _settings.setEngine(current.id);
      }
    }
    if (mode == QualityMode.off) _engineBeforeQuality = null;
    if (persist && _settings.state.qualityMode != mode) {
      _settings.setQualityMode(mode);
    }
    if (state.qualityMode != mode) emit(state.copyWith(qualityMode: mode));
    if (engine == null ||
        (engine.id == state.engine?.id &&
            state.enginesStatus == EnginesStatus.ready)) {
      return;
    }
    final switched = await _switchEngine(
      engine,
      keepResult: false,
      persist: false,
    );
    if (switched && state.input.trim().isNotEmpty && !state.compareMode) {
      await _translate();
    }
  }

  /// Turns quality mode off (state and settings) because the user chose an
  /// engine; returns whether it was on.
  bool _leaveQualityMode() {
    _engineBeforeQuality = null;
    final wasOn = state.qualityMode != QualityMode.off;
    if (_settings.state.qualityMode != QualityMode.off) {
      _settings.setQualityMode(QualityMode.off);
    }
    if (wasOn) emit(state.copyWith(qualityMode: QualityMode.off));
    return wasOn;
  }

  /// The engine [QualityMode.off] switches to: the saved normal engine
  /// (`AppSettings.engineId`), else the one in use before the quality mode
  /// was turned on, else the default (or first) engine other than the
  /// current one (the quality mode's), so that turning a mode off never
  /// keeps translating with its engine while another one is available.
  TranslationEngine? _normalEngine() {
    final engines = state.engines;
    final saved =
        _engineIn(engines, _settings.state.engineId) ??
        _engineIn(engines, _engineBeforeQuality);
    if (saved != null) return saved;
    final current = state.engine?.id;
    for (final engine in [_engineIn(engines, _defaultEngineId), ...engines]) {
      if (engine != null && engine.id != current) return engine;
    }
    return null;
  }

  /// The saved engine id of [mode] (null for [QualityMode.off]).
  String? _qualityEngineId(QualityMode mode) => switch (mode) {
    QualityMode.off => null,
    QualityMode.fast => _settings.state.fastEngineId,
    QualityMode.best => _settings.state.bestEngineId,
  };

  /// The saved quality mode when [engine] is its engine, else
  /// [QualityMode.off].
  QualityMode _modeOf(TranslationEngine engine) {
    final mode = _settings.state.qualityMode;
    return mode != QualityMode.off && _qualityEngineId(mode) == engine.id
        ? mode
        : QualityMode.off;
  }

  static TranslationEngine? _engineIn(
    List<TranslationEngine> engines,
    String? id,
  ) {
    if (id == null) return null;
    for (final engine in engines) {
      if (engine.id == id) return engine;
    }
    return null;
  }

  /// Keeps [TranslateState.fastEngine] / [TranslateState.bestEngine] in
  /// sync with the settings. When the engine of the active mode changes it
  /// is switched to (keeping the output); when it is removed the mode is
  /// turned off and the normal engine comes back.
  void _onSettings(AppSettings settings) {
    final ids = (settings.fastEngineId, settings.bestEngineId);
    if (ids == _qualityIds || isClosed) return;
    _qualityIds = ids;
    final fast = _engineIn(state.engines, settings.fastEngineId);
    final best = _engineIn(state.engines, settings.bestEngineId);
    emit(state.copyWith(fastEngine: () => fast, bestEngine: () => best));
    final mode = state.qualityMode;
    // An engine list load applies the mode itself.
    if (mode == QualityMode.off ||
        _listPending ||
        state.enginesStatus != EnginesStatus.ready) {
      return;
    }
    var engine = mode == QualityMode.fast ? fast : best;
    if (engine == null) {
      engine = _normalEngine();
      _engineBeforeQuality = null;
      _settings.setQualityMode(QualityMode.off);
      emit(state.copyWith(qualityMode: QualityMode.off));
    }
    if (engine != null && engine.id != state.engine?.id) {
      unawaited(_switchEngine(engine, keepResult: true, persist: false));
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
  /// Custom (free-form) languages are kept only for engines that
  /// [TranslationEngine.supportsCustomLanguages].
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
        language.isCustom && !allowCustom
        ? null
        : LanguageMatcher.match(language, sources, allowCustom: allowCustom);
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
    if (_mayAutoTranslateExternal) unawaited(_translate(external: true));
  }

  /// Whether the input may be translated without a user action: external
  /// input as [_mayAutoTranslateExternal], typed input when instant
  /// translation is on for the engine (`instantTranslate` /
  /// `instantTranslateAi`). Never in compare mode.
  bool get _mayAutoTranslate {
    if (_externalPending) return _mayAutoTranslateExternal;
    final engine = state.engine;
    if (engine == null || state.compareMode) return false;
    return engine.isAi
        ? _settings.state.instantTranslateAi
        : _settings.state.instantTranslate;
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
        _clearedExtras(_withoutExtraTranslations(state)).copyWith(
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

  /// Selects the source language, saves it (and records it as recent) and
  /// translates the input again right away.
  ///
  /// A custom free-form source ([Language.isCustom], e.g. "Gen Z slang")
  /// is accepted only while the engine
  /// [TranslationEngine.supportsCustomLanguages] (AI engines with the
  /// general prompt profile); other engines ignore it.
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

  /// Sets both languages of [pair] (e.g. a recent pair from
  /// `AppSettings.recentPairs`) and translates the input again right away,
  /// like [setSource] / [setTarget] (one translation). Each language is
  /// mapped onto the engine's lists; one the engine does not offer (or a
  /// custom language it cannot take) is skipped, and the other one is
  /// still applied.
  void applyLanguagePair(LanguagePair pair) {
    final source = _usableSource(pair.source);
    final target = _usableTarget(pair.target);
    final newSource = source != null && _applySource(source) ? source : null;
    final newTarget = target != null && _applyTarget(target) ? target : null;
    if (newSource == null && newTarget == null) return;
    emit(_clearedExtras(state).copyWith(source: newSource, target: newTarget));
    _retranslate();
  }

  /// Selects pinned language [index] of the pins the engine offers
  /// (`TranslateState.pinnedTargets` of `AppSettings.pinnedLanguages`, the
  /// "Pinned" section of the target language picker) as the target, like
  /// [setTarget]; nothing happens when there is no such pin. For keyboard
  /// shortcuts (Alt+1 … Alt+9) and quick chips.
  void selectPinnedTarget(int index) {
    final pinned = state.pinnedTargets(_settings.state.pinnedLanguages);
    if (index < 0 || index >= pinned.length) return;
    setTarget(pinned[index]);
  }

  /// [language] as listed in the engine's source languages (auto when the
  /// engine detects; custom languages when it takes them), else null.
  Language? _usableSource(Language language) {
    final sources = state.sourceLanguages;
    if (language.isAuto) {
      return sources.isEmpty || sources.contains(Language.auto)
          ? Language.auto
          : null;
    }
    if (language.isCustom) {
      return state.supportsCustomLanguages ? language : null;
    }
    return LanguageMatcher.match(language, sources);
  }

  /// [language] as listed in the engine's target languages (custom
  /// languages when it takes them), else null. Never auto.
  Language? _usableTarget(Language language) => state.usableTarget(language);

  /// Validates and persists a source pick; returns whether it applies.
  bool _applySource(Language language) {
    if (language == state.source) return false;
    if (language.isCustom && !state.supportsCustomLanguages) return false;
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
      _clearedExtras(_withoutExtraTranslations(state)).copyWith(
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
  /// provisional), [external] one of text from outside the app that
  /// nobody asked for (links, shared text); both make the result
  /// [TranslateState.instantResult]. [text] defaults to the input.
  ///
  /// With [extraTargets] the input is also translated into the extra
  /// targets that have no up-to-date translation (see
  /// [_translateExtraTargets]); the future then completes when they are
  /// done too. One-off translations of the main output (refinements) and
  /// the re-translation after a smart swap pass false.
  ///
  /// An extra target left out because it is the language detected in the
  /// shown result ([TranslateState.activeExtraTargets]) is translated once
  /// the main translation finished when the input turns out to be in
  /// another language.
  Future<void> _translate({
    TranslationEngine? engine,
    TranslationOptions? options,
    String? text,
    bool smartSwap = true,
    bool auto = false,
    bool external = false,
    bool extraTargets = true,
  }) {
    final main = _translateMain(
      engine: engine,
      options: options,
      text: text,
      smartSwap: smartSwap,
      auto: auto,
      external: external,
    );
    final selected = engine ?? state.engine;
    final input = text ?? state.input;
    if (!extraTargets ||
        selected == null ||
        input.trim().isEmpty ||
        (state.extraTargets.isEmpty && state.extraTranslations.isEmpty)) {
      return main;
    }
    final base = TranslationRequest(
      text: input,
      source: state.source,
      target: state.target,
      options: options ?? state.options,
      recentSourceLanguages: _recentSourceCodes(),
    );
    final asked = state.activeExtraTargets.toSet();
    final extras = _translateExtraTargets(selected, base);
    final held = main.then(
      (_) => _translateHeldExtraTargets(selected, base, asked),
    );
    return Future.wait([main, ?extras, held]).then((_) {});
  }

  /// The main translation of [_translate].
  Future<void> _translateMain({
    TranslationEngine? engine,
    TranslationOptions? options,
    String? text,
    bool smartSwap = true,
    bool auto = false,
    bool external = false,
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
      recentSourceLanguages: _recentSourceCodes(),
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
    var counted = false;
    // Short input gets a second detection whose verdict only comes with the
    // final result: decide on that one.
    final swapEarly = smartSwap && !_isShortInput(request.text);
    _translation = stream.listen(
      (result) {
        if (!_isCurrentTranslation(id)) return;
        if (swapEarly && !result.isComplete) {
          // AI engines report the detected language before the text: stop
          // at once instead of waiting for a same-language "translation".
          final swapTo = _smartSwapTarget(request, result);
          if (swapTo != null) {
            _smartSwap(
              selected,
              request,
              swapTo,
              auto: auto,
              external: external,
            );
            return;
          }
        }
        if (result.isComplete && !counted) {
          // The provider did the work even when a smart swap follows (but
          // not for results served from the cache).
          counted = true;
          if (!result.fromCache) {
            _recordUsage(selected, input: request.text, output: result.text);
          }
        }
        _onResult(
          selected,
          request,
          result,
          smartSwap: smartSwap,
          auto: auto,
          external: external,
        );
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
    required bool external,
  }) {
    if (!result.isComplete) {
      emit(
        state.copyWith(
          result: () => result,
          resultInput: () => request.text,
          instantResult: auto || external,
        ),
      );
      return;
    }
    final swapTo = smartSwap ? _smartSwapTarget(request, result) : null;
    if (swapTo != null) {
      _smartSwap(engine, request, swapTo, auto: auto, external: external);
      return;
    }
    emit(
      state.copyWith(
        result: () => result,
        resultInput: () => request.text,
        instantResult: auto || external,
        status: TranslateStatus.success,
      ),
    );
    // An extra target in the detected language of the input is dropped
    // (cancelled when in flight).
    _pruneExtraTranslations();
    _record(
      request,
      result,
      engineId: engine.id,
      engineName: engine.name,
      auto: auto,
    );
    _settings.recordPair(
      _languageOf(request.source, result.detectedSource),
      request.target,
    );
    _autoRomanize();
  }

  /// Switches the target to [swapTo] (saved, recorded as recent), tells the
  /// UI ([TranslateState.smartSwapNotice]) and translates [request]'s text
  /// again without smart swap.
  void _smartSwap(
    TranslationEngine engine,
    TranslationRequest request,
    Language swapTo, {
    required bool auto,
    required bool external,
  }) {
    // Hand the caller's future over to the re-translation.
    final done = _translationDone;
    _translationDone = null;
    _settings
      ..setLanguages(target: swapTo)
      ..addRecentLanguage(swapTo);
    final notice = _lastSmartSwap = SmartSwapNotice(
      id: ++_smartSwaps,
      previousTarget: request.target,
      newTarget: swapTo,
    );
    emit(
      state.copyWith(
        target: swapTo,
        result: () => null,
        smartSwapNotice: () => notice,
      ),
    );
    // An extra target that is the new target is not translated twice.
    _pruneExtraTranslations();
    final next = _translate(
      engine: engine,
      options: request.options,
      text: request.text,
      smartSwap: false,
      auto: auto,
      external: external,
      extraTargets: false,
    );
    if (done != null && !done.isCompleted) done.complete(next);
  }

  /// The UI showed [TranslateState.smartSwapNotice]: clears it so it is
  /// shown once. [undoSmartSwap] still works afterwards.
  void consumeSmartSwapNotice() {
    if (state.smartSwapNotice == null) return;
    emit(state.copyWith(smartSwapNotice: () => null));
  }

  /// Undoes the last smart swap: the previous target comes back (saved like
  /// an explicit pick, so no smart swap moves away from it again this
  /// session) and the input is translated into it without smart swap.
  /// Does nothing when the target changed since the swap. Clears the
  /// notice. Completes when the translation finished.
  Future<void> undoSmartSwap() {
    final swap = _lastSmartSwap;
    if (swap == null || state.target != swap.newTarget) {
      return Future.value();
    }
    _lastSmartSwap = null;
    _debounceTimer?.cancel();
    // _applyTarget saves the pick and declines smart swaps away from it.
    if (!_applyTarget(swap.previousTarget)) return Future.value();
    emit(
      _clearedExtras(state)
          .copyWith(target: swap.previousTarget, smartSwapNotice: () => null),
    );
    if (state.input.trim().isEmpty) return Future.value();
    if (state.compareMode) return runCompare();
    return _translate(smartSwap: false);
  }

  /// [source], or for an auto source the language [detected] names (as
  /// listed in the engine's source languages, else from the catalogue);
  /// auto when nothing usable was detected.
  Language _languageOf(Language source, String? detected) {
    if (!source.isAuto || detected == null || detected.trim().isEmpty) {
      return source;
    }
    final known = LanguageCatalog.byCode(detected);
    final wanted = known ?? Language(code: detected, name: detected);
    return LanguageMatcher.match(wanted, state.sourceLanguages) ??
        known ??
        Language.auto;
  }

  /// Codes of the user's recent source languages for
  /// [TranslationRequest.recentSourceLanguages]: the sources of
  /// `AppSettings.recentPairs` (recorded after each translation with the
  /// detected language for an auto source), without auto and custom
  /// languages, most recent first, at most [maxRecentSourceLanguages].
  List<String> _recentSourceCodes() {
    final codes = <String>[];
    final seen = <String>{};
    for (final pair in _settings.state.recentPairs) {
      final source = pair.source;
      if (source.isAuto || source.isCustom) continue;
      if (!seen.add(LanguageMatcher.normalize(source.code))) continue;
      codes.add(source.code);
      if (codes.length == maxRecentSourceLanguages) break;
    }
    return List.unmodifiable(codes);
  }

  /// Most words of input whose detected language is only acted on (smart
  /// swap) once its translation is complete: the repository checks such
  /// input with a second detection, and its verdict
  /// (`TranslationResult.detectionUncertain`) comes with the final result.
  static const _shortInputMaxWords = 3;

  /// Most characters of such input (scripts without spaces).
  static const _shortInputMaxChars = 64;

  static bool _isShortInput(String text) {
    final trimmed = text.trim();
    return trimmed.length <= _shortInputMaxChars &&
        trimmed.split(RegExp(r'\s+')).length <= _shortInputMaxWords;
  }

  /// The language to switch the target to when the detected source equals
  /// the target, else null. Never for a detection the engine marks as
  /// uncertain (`TranslationResult.detectionUncertain`): the UI offers the
  /// other likely languages instead.
  Language? _smartSwapTarget(
    TranslationRequest request,
    TranslationResult result,
  ) {
    final detected = result.detectedSource;
    if (!request.source.isAuto ||
        request.target.isCustom ||
        result.detectionUncertain ||
        detected == null ||
        detected.isEmpty) {
      return null;
    }
    final detectedCode = LanguageMatcher.normalize(detected);
    if (detectedCode != LanguageMatcher.normalize(request.target.code) ||
        detectedCode == _smartSwapDeclined) {
      return null;
    }
    return _targetOtherThan(detectedCode);
  }

  /// A target language for text in [detectedCode] (normalised) other than
  /// that language, or null.
  ///
  /// Candidates: recent, then pinned languages, the device languages,
  /// English (for non-English text), then a few widely used languages.
  /// Never an arbitrary list entry.
  Language? _targetOtherThan(String detectedCode) {
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

  /// Applies a refinement chip (or toggles it off).
  ///
  /// **AI engines with the general prompt profile** (when there is a
  /// finished, current output, see [TranslateState.refinesOutput]) revise
  /// the current translation with `TranslationRepository.refine` instead of
  /// translating the input again, so chips stack:
  ///
  /// * The output keeps the current translation while the refinement runs
  ///   ([TranslateState.pendingRefinement]); the refined one replaces it
  ///   when complete and [suggestion] is appended to
  ///   [TranslateState.appliedRefinements] with the translation from before
  ///   it. Output extras (alternatives, insights, explanation,
  ///   romanization, alignment) are reset; the chips stay.
  /// * A chip whose `exclusiveGroup` already has an applied chip replaces
  ///   that chip: the translation from before the replaced chip is refined,
  ///   and the replaced chip **and every chip applied after it** are
  ///   dropped (their effect is lost; apply them again if wanted).
  /// * Applying an applied chip again toggles it off: the translation from
  ///   before it comes back (no request), and chips applied after it are
  ///   dropped as well.
  /// * Applying the chip that is in flight cancels it; applying another
  ///   chip while one is in flight cancels the first.
  /// * A failure keeps the translation and sets
  ///   [TranslateState.refinementError].
  ///
  /// **Other engines** (Mozhi and other machine translation engines,
  /// translation-only AI models), or when there is no finished output: the
  /// input is translated again with the instruction as a one-off (the
  /// assist AI engine is used when the main engine is not AI); nothing is
  /// tracked.
  ///
  /// Fetched suggestions are model-generated, so their instruction is
  /// passed as a lower-trust refinement (see [refinementInstruction]).
  /// Applied refinements are cleared when the input, options, languages or
  /// engine change and when a new translation runs.
  Future<void> applySuggestion(RefinementSuggestion suggestion) {
    _debounceTimer?.cancel();
    final pending = state.pendingRefinement;
    if (pending != null) {
      _cancelPendingRefinement();
      if (pending == suggestion) return Future.value();
    }
    final applied = state.appliedRefinements;
    final index = applied.indexWhere((a) => a.suggestion == suggestion);
    if (index >= 0) {
      _restoreRefinement(index);
      return Future.value();
    }
    final instruction = refinementInstruction(suggestion);
    if (instruction.isEmpty) return Future.value();
    final engine = state.engine;
    if (engine != null && state.refinesOutput) {
      return _refine(engine, suggestion, instruction);
    }
    final translator = state.isAiEngine
        ? state.engine
        : state.assistEngine ?? state.engine;
    return _translate(
      engine: translator,
      options: state.options.copyWith(instructions: instruction),
      extraTargets: false,
    );
  }

  /// Revises the current output with [instruction] (see [applySuggestion]).
  Future<void> _refine(
    TranslationEngine engine,
    RefinementSuggestion suggestion,
    String instruction,
  ) {
    final applied = state.appliedRefinements;
    final group = suggestion.exclusiveGroup;
    final replaced = group == null
        ? -1
        : applied.indexWhere((a) => a.suggestion.exclusiveGroup == group);
    final kept = replaced < 0 ? applied : applied.sublist(0, replaced);
    final base = replaced < 0 ? state.result! : applied[replaced].previous;
    final request = TranslationRequest(
      text: state.input,
      source: _effectiveSource(),
      target: state.target,
      options: state.options,
      recentSourceLanguages: _recentSourceCodes(),
    );
    final token = _invalidateExtra(_Extra.refinement);
    final done = _refinementDone = Completer<void>();
    emit(
      state.copyWith(
        pendingRefinement: () => suggestion,
        refinementError: () => null,
      ),
    );

    void finish() {
      _refinement = null;
      _complete(done);
    }

    void fail(Object error) {
      finish();
      emit(
        state.copyWith(
          pendingRefinement: () => null,
          refinementError: () => error,
        ),
      );
    }

    final Stream<TranslationResult> stream;
    try {
      stream = _repository.refine(
        engine,
        request,
        currentTranslation: base.text,
        instruction: instruction,
      );
    } on Object catch (error) {
      fail(error);
      return done.future;
    }
    _refinement = stream.listen(
      (refined) {
        if (!refined.isComplete || !_isCurrentExtra(_Extra.refinement, token)) {
          return;
        }
        _recordUsage(
          engine,
          input: [request.text, base.text, instruction].join('\n'),
          output: refined.text,
        );
        // The detection belongs to the input, which did not change.
        final result = refined.copyWith(
          detectedSource: base.detectedSource,
          detectionUncertain: base.detectionUncertain,
          detectedAlternatives: base.detectedAlternatives,
        );
        emit(
          _clearedOutputExtras(state).copyWith(
            result: () => result,
            instantResult: false,
            status: TranslateStatus.success,
            error: () => null,
            appliedRefinements: List<AppliedRefinement>.unmodifiable([
              ...kept,
              AppliedRefinement(suggestion: suggestion, previous: base),
            ]),
            pendingRefinement: () => null,
          ),
        );
        finish();
        _recordCurrent();
        _autoRomanize();
      },
      onError: (Object error) {
        if (!_isCurrentExtra(_Extra.refinement, token)) return;
        if (error is! UnsupportedError) {
          fail(error);
          return;
        }
        // A translation-only model cannot follow instructions: translate
        // again with the instruction instead (and hand the future over).
        _refinement = null;
        _refinementDone = null;
        emit(state.copyWith(pendingRefinement: () => null));
        done.complete(
          _translate(
            engine: engine,
            options: state.options.copyWith(instructions: instruction),
            extraTargets: false,
          ),
        );
      },
      onDone: () {
        if (!_isCurrentExtra(_Extra.refinement, token)) return;
        finish();
        if (state.pendingRefinement != null) {
          emit(state.copyWith(pendingRefinement: () => null));
        }
      },
      cancelOnError: true,
    );
    return done.future;
  }

  /// Toggles off the applied refinement at [index]: the translation from
  /// before it comes back and it is dropped with every later one.
  void _restoreRefinement(int index) {
    final applied = state.appliedRefinements;
    emit(
      _clearedOutputExtras(state).copyWith(
        result: () => applied[index].previous,
        instantResult: false,
        status: TranslateStatus.success,
        error: () => null,
        appliedRefinements: List<AppliedRefinement>.unmodifiable(
          applied.sublist(0, index),
        ),
        refinementError: () => null,
      ),
    );
    _recordCurrent();
    _autoRomanize();
  }

  /// Cancels the refinement in flight (the output is unchanged).
  void _cancelPendingRefinement() {
    if (state.pendingRefinement == null) return;
    _invalidateExtra(_Extra.refinement);
    emit(state.copyWith(pendingRefinement: () => null));
  }

  void _cancelRefinement() {
    unawaited(_refinement?.cancel());
    _refinement = null;
    final done = _refinementDone;
    _refinementDone = null;
    if (done != null) _complete(done);
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
  /// history. A refinement in flight is cancelled; applied refinements are
  /// kept (toggling one off restores the translation from before it).
  void useAlternative(String text) {
    _cancelPendingRefinement();
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
      _clearedResultExtras(state).copyWith(
        result: () => _withOutput(result, output, isComplete: true),
        instantResult: false,
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
    _autoRomanize();
  }

  /// [result] with [text] as its output. The transliteration of the old
  /// output (Mozhi) no longer applies and is dropped.
  static TranslationResult _withOutput(
    TranslationResult result,
    String text, {
    bool? isComplete,
  }) => TranslationResult(
    engineId: result.engineId,
    engineName: result.engineName,
    text: text,
    isComplete: isComplete ?? result.isComplete,
    detectedSource: result.detectedSource,
    sourceTransliteration: result.sourceTransliteration,
    wordChoices: result.wordChoices,
    sourceSynonyms: result.sourceSynonyms,
    targetSynonyms: result.targetSynonyms,
    elapsed: result.elapsed,
    fromCache: result.fromCache,
    detectionUncertain: result.detectionUncertain,
    detectedAlternatives: result.detectedAlternatives,
  );

  /// Replaces the occurrence of `insight.targetText` the insight refers to
  /// (see [locateInsight]; [offset] is the start of the tapped highlight
  /// when known) with [variation], and updates the insight's targetText.
  void applyVariation(WordInsight insight, String variation, {int? offset}) {
    _cancelPendingRefinement();
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
      _clearedResultExtras(state).copyWith(
        result: () => _withOutput(result, text),
        instantResult: false,
        insights: state.insights
            .map((item) => identical(item, insight) ? updated : item)
            .toList(),
      ),
    );
    _recordCurrent();
    _autoRomanize();
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
  /// only for custom languages) and collects their results progressively.
  Future<void> runCompare() {
    _debounceTimer?.cancel();
    final text = state.input;
    if (text.trim().isEmpty) return Future.value();
    final ids = _settings.state.compareEngineIds;
    var engines = ids.isEmpty
        ? state.engines
        : state.engines.where((e) => ids.contains(e.id)).toList();
    if (engines.isEmpty) engines = state.engines;
    if (state.target.isCustom || state.source.isCustom) {
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
      recentSourceLanguages: _recentSourceCodes(),
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
        final result = entry.result;
        if (result != null && result.isComplete && !result.fromCache) {
          for (final engine in engines) {
            if (engine.id == entry.id) {
              _recordUsage(engine, input: text, output: result.text);
              break;
            }
          }
        }
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

  /// Selects [entry] as the main result (and its engine; choosing another
  /// engine turns quality mode off, like [selectEngine]).
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
        instantResult: false,
        resultInput: () => state.input,
        status: TranslateStatus.success,
        error: () => null,
      ),
    );
    _recordCurrent();
    if (engine.id != state.engine?.id) {
      // Picking another engine's result chooses that engine.
      _leaveQualityMode();
      unawaited(_switchEngine(engine, keepResult: true));
    }
    _autoRomanize();
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
  // Extra targets
  // ---------------------------------------------------------------------

  /// Sets the additional target languages ("Also translate into…"): auto
  /// and duplicates are dropped, and at most [maxExtraTargets] are kept (in
  /// the given order). They last for the session.
  ///
  /// The input is translated into each of
  /// [TranslateState.activeExtraTargets] with every translation of the
  /// input: same engine and options, one request per language, only where
  /// the main translation runs (instant translation where it is free or the
  /// user opted in, otherwise on Translate). Results are never saved in
  /// history; each finished request is counted as provider usage (unless
  /// served from the cache).
  ///
  /// A language added while the input has a current translation (or one in
  /// flight) is translated right away; translations of removed languages
  /// are cancelled and dropped. The other languages are left alone: one in
  /// flight is not sent again, and a failed one waits for Retry (or the
  /// next translation).
  void setExtraTargets(List<Language> targets) {
    final next = <Language>[];
    for (final language in targets) {
      if (language.isAuto || next.contains(language)) continue;
      next.add(language);
      if (next.length == maxExtraTargets) break;
    }
    if (_sameLanguages(next, state.extraTargets)) return;
    emit(state.copyWith(extraTargets: List<Language>.unmodifiable(next)));
    _pruneExtraTranslations();
    final engine = state.engine;
    final requested =
        state.status == TranslateStatus.translating ||
        (state.result != null && !state.isResultStale);
    if (engine == null ||
        state.compareMode ||
        state.input.trim().isEmpty ||
        !requested) {
      return;
    }
    final extras = _translateExtraTargets(
      engine,
      _extraTargetsRequest(),
      retryFailed: false,
    );
    if (extras != null) unawaited(extras);
  }

  /// Adds [language] to the extra targets, or removes it when it is one
  /// ([TranslateState.isExtraTarget]: also a pick the engine lists as
  /// [language]); see [setExtraTargets]. Nothing is added when
  /// [maxExtraTargets] are set already.
  void toggleExtraTarget(Language language) {
    final targets = state.extraTargets;
    bool picks(Language chosen) =>
        chosen == language || state.usableTarget(chosen) == language;
    if (targets.any(picks)) {
      setExtraTargets([
        for (final target in targets)
          if (!picks(target)) target,
      ]);
    } else if (targets.length < maxExtraTargets) {
      setExtraTargets([...targets, language]);
    }
  }

  /// Translates the input into the extra target [target] (one of
  /// [TranslateState.activeExtraTargets]) again, e.g. after a failure.
  /// Completes when it is done.
  Future<void> retryExtraTarget(Language target) {
    final engine = state.engine;
    if (engine == null ||
        state.input.trim().isEmpty ||
        !state.activeExtraTargets.contains(target)) {
      return Future.value();
    }
    return _startExtraTargets(engine, _extraTargetsRequest(), [target]);
  }

  /// Uses the finished translation into the extra target [target] as the
  /// input: it replaces the input (like pasting it). A chosen source
  /// language becomes [target] (as the engine lists it among its source
  /// languages; detection when it does not); the input is then translated
  /// like typed text (instant translation only where it is free or the user
  /// opted in). [undoInsertExtraTranslation] brings the previous input and
  /// source language back.
  void insertExtraTranslation(Language target) {
    final translation = state.extraTranslationFor(target);
    final result = translation?.result;
    if (result == null || !result.isComplete || result.text.trim().isEmpty) {
      return;
    }
    final previous = state;
    if (!state.source.isAuto) {
      final source = _usableSource(target) ?? _usableSource(Language.auto);
      if (source != null && _applySource(source)) {
        emit(_clearedExtras(state).copyWith(source: source));
      }
    }
    setInput(result.text);
    if (state.input == previous.input && state.source == previous.source) {
      return;
    }
    _lastInsert = (
      input: previous.input,
      source: previous.source,
      inserted: state.input,
    );
  }

  /// Undoes the last [insertExtraTranslation] while the input is still the
  /// text it inserted: the previous input and source language (saved again)
  /// come back. The input is translated again like typed text only when
  /// its translation is no longer the shown result. Does nothing otherwise.
  void undoInsertExtraTranslation() {
    final last = _lastInsert;
    _lastInsert = null;
    if (last == null || state.input != last.inserted) return;
    final source = _usableSource(last.source);
    if (source != null && _applySource(source)) {
      emit(_clearedExtras(state).copyWith(source: source));
    }
    final shown = state.result != null && state.resultInput == last.input;
    _externalPending = false;
    _applyInput(last.input, maxLength: maxInputLength, instant: !shown);
  }

  /// A request of the input with the current languages and options.
  TranslationRequest _extraTargetsRequest() => TranslationRequest(
    text: state.input,
    source: state.source,
    target: state.target,
    options: state.options,
    recentSourceLanguages: _recentSourceCodes(),
  );

  /// Translates [base] (its text, source and options) with [engine] into
  /// each of [TranslateState.activeExtraTargets] (other than [except]) that
  /// has no up-to-date translation (a finished one of the same request and
  /// engine). A target whose translation of that request is in flight is
  /// not sent again (its future is waited for); one whose last request for
  /// it ended without a translation (failed) is sent again only with
  /// [retryFailed]. Returns null when there is nothing to wait for.
  Future<void>? _translateExtraTargets(
    TranslationEngine engine,
    TranslationRequest base, {
    bool retryFailed = true,
    Set<Language> except = const {},
  }) {
    _pruneExtraTranslations();
    final targets = <Language>[];
    final waiting = <Future<void>>[];
    for (final target in state.activeExtraTargets) {
      if (except.contains(target)) continue;
      final request = base.copyWith(target: target);
      final translation = state.extraTranslationFor(target);
      if (_isUpToDate(translation, engine, request)) continue;
      final inFlight = _extraTargetsInFlight[target];
      if (inFlight != null &&
          inFlight.$1 == engine.id &&
          inFlight.$2 == request) {
        if (_extraTargetDone[target] case final done?) waiting.add(done.future);
        continue;
      }
      if (!retryFailed && _endedWithout(translation, engine, request)) {
        continue;
      }
      targets.add(target);
    }
    if (targets.isEmpty && waiting.isEmpty) return null;
    return Future.wait([
      ...waiting,
      if (targets.isNotEmpty) _startExtraTargets(engine, base, targets),
    ]).then((_) {});
  }

  /// After the main translation of [base] by [_translate]: translates the
  /// extra targets that were left out of [asked] because they were the
  /// language detected in the previous result, now that the new result
  /// says the input is in another language. Nothing happens when the main
  /// translation failed or something changed meanwhile (a newer
  /// translation handles its own extra targets).
  Future<void> _translateHeldExtraTargets(
    TranslationEngine engine,
    TranslationRequest base,
    Set<Language> asked,
  ) {
    if (isClosed ||
        state.compareMode ||
        state.engine?.id != engine.id ||
        state.status != TranslateStatus.success ||
        state.resultInput != base.text ||
        state.input != base.text ||
        state.source != base.source ||
        state.options != base.options) {
      return Future.value();
    }
    return _translateExtraTargets(
          engine,
          base,
          retryFailed: false,
          except: asked,
        ) ??
        Future.value();
  }

  /// Whether the last request into [translation]'s target was [request] on
  /// [engine] and it ended without a translation (failed, or the stream
  /// closed without a result).
  static bool _endedWithout(
    ExtraTranslation? translation,
    TranslationEngine engine,
    TranslationRequest request,
  ) =>
      translation != null &&
      translation.status != TranslateStatus.translating &&
      translation.result == null &&
      translation.engineId == engine.id &&
      translation.request == request;

  static bool _isUpToDate(
    ExtraTranslation? translation,
    TranslationEngine engine,
    TranslationRequest request,
  ) =>
      translation != null &&
      translation.status == TranslateStatus.success &&
      (translation.result?.isComplete ?? false) &&
      translation.engineId == engine.id &&
      translation.request == request;

  /// Starts the translations of [base] into [targets] (cancelling ones in
  /// flight for them); completes when all are done.
  Future<void> _startExtraTargets(
    TranslationEngine engine,
    TranslationRequest base,
    List<Language> targets,
  ) {
    final starts = <(Language, TranslationRequest, int)>[];
    var translations = state.extraTranslations;
    for (final target in targets) {
      _cancelExtraTarget(target);
      final token = _extraTargetTokens[target] = ++_extraTargetRequests;
      final request = base.copyWith(target: target);
      _extraTargetsInFlight[target] = (engine.id, request);
      starts.add((target, request, token));
      final previous = _extraTranslationIn(translations, target);
      // The previous translation stays (dimmed when stale) until the new
      // one arrives, like the main result.
      final next = (previous ?? ExtraTranslation(target: target)).copyWith(
        status: TranslateStatus.translating,
        request: () => previous?.result == null ? request : previous!.request,
        engineId: () =>
            previous?.result == null ? engine.id : previous!.engineId,
        error: () => null,
      );
      translations = _replaceExtraTranslation(translations, next);
    }
    emit(state.copyWith(extraTranslations: translations));
    return Future.wait([
      for (final (target, request, token) in starts)
        _listenExtraTarget(engine, target, request, token),
    ]).then((_) {});
  }

  Future<void> _listenExtraTarget(
    TranslationEngine engine,
    Language target,
    TranslationRequest request,
    int token,
  ) {
    final done = _extraTargetDone[target] = Completer<void>();
    bool current() => !isClosed && _extraTargetTokens[target] == token;

    void finish() {
      _extraTargetSubscriptions.remove(target);
      if (identical(_extraTargetDone[target], done)) {
        _extraTargetDone.remove(target);
        _extraTargetsInFlight.remove(target);
      }
      _complete(done);
    }

    void fail(Object error) {
      finish();
      _updateExtraTranslation(
        target,
        (translation) => translation.copyWith(
          status: TranslateStatus.failure,
          result: () => null,
          request: () => request,
          engineId: () => engine.id,
          error: () => error,
        ),
      );
    }

    final Stream<TranslationResult> stream;
    try {
      stream = _repository.translate(engine, request);
    } on Object catch (error) {
      fail(error);
      return done.future;
    }
    var counted = false;
    _extraTargetSubscriptions[target] = stream.listen(
      (result) {
        if (!current()) return;
        if (result.isComplete && !counted) {
          counted = true;
          if (!result.fromCache) {
            _recordUsage(engine, input: request.text, output: result.text);
          }
        }
        _updateExtraTranslation(
          target,
          (translation) => translation.copyWith(
            status: result.isComplete
                ? TranslateStatus.success
                : TranslateStatus.translating,
            result: () => result,
            request: () => request,
            engineId: () => engine.id,
          ),
        );
      },
      onError: (Object error) {
        if (current()) fail(error);
      },
      onDone: () {
        if (!current()) return;
        finish();
        _updateExtraTranslation(
          target,
          (translation) => translation.status == TranslateStatus.translating
              ? translation.copyWith(
                  status: translation.result == null
                      ? TranslateStatus.idle
                      : TranslateStatus.success,
                )
              : translation,
        );
      },
      cancelOnError: true,
    );
    return done.future;
  }

  /// Applies [change] to the translation into [target] (when there is
  /// one) and emits.
  void _updateExtraTranslation(
    Language target,
    ExtraTranslation Function(ExtraTranslation translation) change,
  ) {
    final translations = state.extraTranslations;
    final translation = _extraTranslationIn(translations, target);
    if (translation == null) return;
    final next = change(translation);
    if (next == translation) return;
    emit(
      state.copyWith(
        extraTranslations: _replaceExtraTranslation(translations, next),
      ),
    );
  }

  static ExtraTranslation? _extraTranslationIn(
    List<ExtraTranslation> translations,
    Language target,
  ) {
    for (final translation in translations) {
      if (translation.target == target) return translation;
    }
    return null;
  }

  /// [translations] with [translation] in place of the one into its target
  /// (appended when there is none).
  static List<ExtraTranslation> _replaceExtraTranslation(
    List<ExtraTranslation> translations,
    ExtraTranslation translation,
  ) {
    final index = translations.indexWhere(
      (item) => item.target == translation.target,
    );
    final next = [...translations];
    if (index < 0) {
      next.add(translation);
    } else {
      next[index] = translation;
    }
    return List<ExtraTranslation>.unmodifiable(next);
  }

  /// Cancels and drops the translations into languages that are no longer
  /// [TranslateState.activeExtraTargets].
  void _pruneExtraTranslations() {
    final active = state.activeExtraTargets;
    final translations = state.extraTranslations;
    final kept = <ExtraTranslation>[];
    for (final translation in translations) {
      if (active.contains(translation.target)) {
        kept.add(translation);
      } else {
        _cancelExtraTarget(translation.target);
      }
    }
    if (kept.length != translations.length) {
      emit(
        state.copyWith(
          extraTranslations: List<ExtraTranslation>.unmodifiable(kept),
        ),
      );
    }
  }

  /// Cancels the translation into [target] in flight (its future
  /// completes).
  void _cancelExtraTarget(Language target) {
    _extraTargetTokens.remove(target);
    _extraTargetsInFlight.remove(target);
    unawaited(_extraTargetSubscriptions.remove(target)?.cancel());
    final done = _extraTargetDone.remove(target);
    if (done != null) _complete(done);
  }

  /// Cancels every extra target translation in flight and returns [base]
  /// without extra translations (the main result was dropped).
  TranslateState _withoutExtraTranslations(TranslateState base) {
    [..._extraTargetTokens.keys].forEach(_cancelExtraTarget);
    return base.copyWith(extraTranslations: const []);
  }

  static bool _sameLanguages(List<Language> a, List<Language> b) {
    if (a.length != b.length) return false;
    for (var i = 0; i < a.length; i++) {
      if (a[i] != b[i]) return false;
    }
    return true;
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
    usageText: _alternativesText,
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
    usageText: _insightsText,
    ready: (s, value) =>
        s.copyWith(insightsStatus: ExtraStatus.ready, insights: value),
    failed: (s) => s.copyWith(insightsStatus: ExtraStatus.failure),
  );

  Future<void> loadSuggestions() => _loadExtra(
    _Extra.suggestions,
    loading: (s) => s.copyWith(suggestionsStatus: ExtraStatus.loading),
    fetch: _repository.getSuggestions,
    usageText: _suggestionsText,
    ready: (s, value) => s.copyWith(
      suggestionsStatus: ExtraStatus.ready,
      suggestions: _mergeSuggestions(value, applied: s.appliedSuggestions),
    ),
    failed: (s) => s.copyWith(suggestionsStatus: ExtraStatus.failure),
  );

  /// [RefinementSuggestion.defaults], then the [applied] chips that are not
  /// among them (so a reload never hides a selected chip), then fetched
  /// suggestions whose label and instruction are new (case-insensitive)
  /// and whose instruction survives [sanitizeRefinement].
  static List<RefinementSuggestion> _mergeSuggestions(
    List<RefinementSuggestion> fetched, {
    List<RefinementSuggestion> applied = const [],
  }) {
    final merged = [
      ...RefinementSuggestion.defaults,
      for (final suggestion in applied)
        if (!RefinementSuggestion.defaults.contains(suggestion)) suggestion,
    ];
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

    final request = _extrasRequest();
    final Stream<String> stream;
    try {
      stream = _repository.explain(engine, request, output, question: question);
    } on Object catch (error) {
      fail(error);
      return done.future;
    }
    final explanation = StringBuffer();
    _explanation = stream.listen(
      (chunk) {
        explanation.write(chunk);
        if (!_isCurrentExtra(_Extra.explain, token)) return;
        emit(state.copyWith(explanation: state.explanation + chunk));
      },
      onError: (Object error) {
        if (_isCurrentExtra(_Extra.explain, token)) fail(error);
      },
      onDone: () {
        _recordUsage(
          engine,
          input: _extrasUsageInput(request, output, question: question),
          output: explanation.toString(),
        );
        if (!_isCurrentExtra(_Extra.explain, token)) return;
        _explanation = null;
        emit(state.copyWith(explainStatus: ExtraStatus.ready));
        _complete(done);
      },
      cancelOnError: true,
    );
    return done.future;
  }

  /// Dictionary for the (short) input, with
  /// [TranslateState.dictionaryVerbosity].
  Future<void> lookUp() => _lookUp(state.input.trim());

  /// Looks [word] up instead of the input, keeping the languages: to follow
  /// `DictionaryEntry.didYouMean` or one of its `relatedWords`. The word is
  /// reduced to one line of at most [maxDictionaryWordLength] characters
  /// (it comes from model output). [TranslateState.dictionaryQuery] is
  /// [word] then.
  Future<void> lookUpWord(String word) => _lookUp(_dictionaryWord(word));

  /// Sets how much the dictionary asks for; looks the shown (or loading)
  /// word up again with it.
  Future<void> setDictionaryVerbosity(DictionaryVerbosity verbosity) {
    if (verbosity == state.dictionaryVerbosity) return Future.value();
    final query = state.dictionaryQuery;
    final again =
        query != null &&
        (state.dictionary != null ||
            state.dictionaryStatus == ExtraStatus.loading);
    emit(state.copyWith(dictionaryVerbosity: verbosity));
    return again ? _lookUp(query) : Future.value();
  }

  Future<void> _lookUp(String word) async {
    final engine = state.assistEngine;
    if (engine == null || word.isEmpty) return;
    final token = _invalidateExtra(_Extra.dictionary);
    emit(
      state.copyWith(
        dictionaryStatus: ExtraStatus.loading,
        dictionaryQuery: () => word,
        extraError: () => null,
      ),
    );
    try {
      final entry = await _repository.lookUp(
        engine,
        word,
        source: _effectiveSource(),
        target: state.target,
        verbosity: state.dictionaryVerbosity,
      );
      _recordUsage(engine, input: word, output: _dictionaryText(entry));
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

  /// [word] as one line of at most [maxDictionaryWordLength] characters
  /// without control or bidi characters.
  static String _dictionaryWord(String word) {
    final text = word
        .replaceAll(_unsafeRefinement, ' ')
        .replaceAll(RegExp(r'\s+'), ' ')
        .trim();
    if (text.length <= maxDictionaryWordLength) return text;
    return _truncate(text, maxDictionaryWordLength).trimRight();
  }

  /// Shows the output in the Latin script ([TranslateState.romanization]).
  ///
  /// Uses the result's own transliteration when it has one (Mozhi; no
  /// request). Otherwise asks the AI [TranslateState.assistEngine]
  /// (`TranslationRepository.romanize`), but only when the target language
  /// uses a non-Latin script or the output has non-Latin letters (see
  /// [TranslateState.canRomanize]). Does nothing while it is loading or
  /// loaded. Errors end up in [TranslateState.romanizationError]; nothing
  /// is thrown.
  ///
  /// Called automatically after each new result when
  /// `AppSettings.showTransliteration` is on and that costs nothing: the
  /// result has a transliteration, or the extras engine runs locally
  /// (`TranslationEngine.isLocal`). The romanization is reset whenever the
  /// result changes.
  Future<void> loadRomanization() async {
    if (!state.canRomanize ||
        state.romanizationStatus == ExtraStatus.loading ||
        state.romanizationStatus == ExtraStatus.ready) {
      return;
    }
    final result = state.result!;
    final transliteration = result.targetTransliteration.trim();
    final token = _invalidateExtra(_Extra.romanization);
    if (transliteration.isNotEmpty) {
      emit(
        state.copyWith(
          romanizationStatus: ExtraStatus.ready,
          romanization: () => transliteration,
          romanizationError: () => null,
        ),
      );
      return;
    }
    final engine = state.assistEngine!;
    emit(
      state.copyWith(
        romanizationStatus: ExtraStatus.loading,
        romanizationError: () => null,
      ),
    );
    try {
      final text = await _repository.romanize(
        engine,
        text: result.text,
        language: state.target,
      );
      // Text without non-Latin letters comes back without a request.
      if (LanguageCatalog.hasNonLatinLetters(result.text)) {
        _recordUsage(engine, input: result.text, output: text);
      }
      if (!_isCurrentResultExtra(_Extra.romanization, token, result)) return;
      emit(
        state.copyWith(
          romanizationStatus: ExtraStatus.ready,
          romanization: () => text,
        ),
      );
    } on Object catch (error) {
      if (!_isCurrentResultExtra(_Extra.romanization, token, result)) return;
      emit(
        state.copyWith(
          romanizationStatus: ExtraStatus.failure,
          romanizationError: () => error,
        ),
      );
    }
  }

  /// Romanizes the new result on its own when the user wants to see
  /// transliterations and it costs nothing (see [loadRomanization]).
  void _autoRomanize() {
    final result = state.result;
    if (result == null || !_settings.state.showTransliteration) return;
    final free =
        result.targetTransliteration.trim().isNotEmpty ||
        (state.assistEngine?.isLocal ?? false);
    if (free && state.canRomanize) unawaited(loadRomanization());
  }

  /// Finds the corresponding phrases of the input and the output
  /// ([TranslateState.alignment], on demand) with the AI
  /// [TranslateState.assistEngine] (`TranslationRepository.align`; only the
  /// beginning of long texts is aligned). Needs a finished, current output
  /// ([TranslateState.canAlign]); does nothing while it is loading or
  /// loaded. Errors end up in [TranslateState.alignmentError]; nothing is
  /// thrown. Reset whenever the input or the result changes.
  Future<void> loadAlignment() async {
    if (!state.canAlign ||
        state.alignmentStatus == ExtraStatus.loading ||
        state.alignmentStatus == ExtraStatus.ready) {
      return;
    }
    final engine = state.assistEngine!;
    final result = state.result!;
    final source = state.input;
    final translation = result.text;
    final token = _invalidateExtra(_Extra.alignment);
    emit(
      state.copyWith(
        alignmentStatus: ExtraStatus.loading,
        alignmentFocus: () => null,
        alignmentError: () => null,
      ),
    );
    try {
      final spans = await _repository.align(
        engine,
        source: source,
        translation: translation,
        sourceLanguage: _effectiveSource(),
        targetLanguage: state.target,
      );
      _recordUsage(
        engine,
        input: '$source\n$translation',
        output: _alignmentText(spans, source, translation),
      );
      if (!_isCurrentResultExtra(_Extra.alignment, token, result)) return;
      emit(
        state.copyWith(
          alignmentStatus: ExtraStatus.ready,
          alignment: List<AlignedSpan>.unmodifiable(spans),
        ),
      );
    } on Object catch (error) {
      if (!_isCurrentResultExtra(_Extra.alignment, token, result)) return;
      emit(
        state.copyWith(
          alignmentStatus: ExtraStatus.failure,
          alignmentError: () => error,
        ),
      );
    }
  }

  /// Highlights the [TranslateState.alignment] pair at [index] (null
  /// clears the highlight); an index out of range is ignored. Use
  /// [TranslateState.alignmentIndexAtSource] /
  /// [TranslateState.alignmentIndexAtTarget] to find the pair at a tapped
  /// character.
  void focusAlignment(int? index) {
    if (index != null && (index < 0 || index >= state.alignment.length)) {
      return;
    }
    if (index == state.alignmentFocus) return;
    emit(
      state.copyWith(
        alignmentFocus: () => index,
        // One highlight in the texts at a time.
        meaningFocus: index == null ? null : () => null,
      ),
    );
  }

  // ---------------------------------------------------------------------
  // Meaning check
  // ---------------------------------------------------------------------

  /// Checks, on demand, whether the output means the same as the input
  /// (needs [TranslateState.canCheckMeaning]; does nothing while a check is
  /// loading or loaded):
  ///
  /// * With an AI [TranslateState.assistEngine] that has extras
  ///   ([TranslateState.meaningUsesAi]), `TranslationRepository
  ///   .checkMeaning` translates the output back, compares the meanings and
  ///   lists the differences ([TranslateState.meaningCheck]); problems are
  ///   written in [uiLanguage] (an English language name, e.g. "German").
  /// * Otherwise the output is translated back into the source language
  ///   (the chosen one, or the detected one) with the main engine
  ///   (`TranslationRepository.backTranslateResult`), and only the
  ///   back-translation is shown ([TranslateState.backTranslation]).
  ///
  /// Every finished request is counted as provider usage (a back-translation
  /// served from the cache is not). Errors end up in
  /// [TranslateState.meaningError]; nothing is thrown. The check is reset
  /// whenever the input or the result changes, and never reloaded on its
  /// own.
  Future<void> checkMeaning({String uiLanguage = 'English'}) async {
    if (!state.canCheckMeaning ||
        state.meaningStatus == ExtraStatus.loading ||
        state.meaningStatus == ExtraStatus.ready) {
      return;
    }
    final result = state.result!;
    final source = state.input;
    final translation = result.text;
    final useAi = state.meaningUsesAi;
    final token = _invalidateExtra(_Extra.meaning);
    emit(_clearedMeaning(state).copyWith(meaningStatus: ExtraStatus.loading));
    try {
      final TranslateState ready;
      if (useAi) {
        final engine = state.assistEngine!;
        final check = await _repository.checkMeaning(
          engine,
          source: source,
          translation: translation,
          sourceLanguage: _effectiveSource(),
          targetLanguage: state.target,
          uiLanguage: uiLanguage,
        );
        _recordUsage(
          engine,
          input: '$source\n$translation',
          output: _meaningText(check),
        );
        ready = state.copyWith(
          meaningStatus: ExtraStatus.ready,
          meaningCheck: () => check,
        );
      } else {
        final engine = state.engine!;
        final back = await _repository.backTranslateResult(
          engine,
          translation: translation,
          from: _backTranslationSource(),
          to: _backTranslationTarget(),
        );
        if (!back.fromCache) {
          _recordUsage(engine, input: translation, output: back.text);
        }
        ready = state.copyWith(
          meaningStatus: ExtraStatus.ready,
          backTranslation: () => back.text,
        );
      }
      if (!_isCurrentResultExtra(_Extra.meaning, token, result)) return;
      emit(ready);
    } on Object catch (error) {
      if (!_isCurrentResultExtra(_Extra.meaning, token, result)) return;
      emit(
        state.copyWith(
          meaningStatus: ExtraStatus.failure,
          meaningError: () => error,
        ),
      );
    }
  }

  /// Highlights the meaning check issue at [index] in the input and the
  /// output (null clears the highlight; an index out of range is ignored).
  /// Clears the alignment highlight.
  void focusMeaningIssue(int? index) {
    final issues = state.meaningCheck?.issues ?? const <MeaningIssue>[];
    if (index != null && (index < 0 || index >= issues.length)) return;
    if (index == state.meaningFocus) return;
    emit(
      state.copyWith(
        meaningFocus: () => index,
        alignmentFocus: index == null ? null : () => null,
      ),
    );
  }

  /// Hides the meaning check (a check in flight is dropped).
  void clearMeaningCheck() {
    _invalidateExtra(_Extra.meaning);
    if (state.meaningStatus == ExtraStatus.idle) return;
    emit(_clearedMeaning(state));
  }

  /// The target language as the source of the back-translation (as the
  /// engine lists it among its source languages when it does).
  Language _backTranslationSource() =>
      LanguageMatcher.match(state.target, state.sourceLanguages) ??
      state.target;

  /// The language of the input as the target of the back-translation: the
  /// chosen source, or the detected one (as the engine lists it among its
  /// target languages when it does).
  Language _backTranslationTarget() {
    final source = state.source;
    final detected = state.result?.detectedSource?.trim() ?? '';
    final wanted = source.isAuto
        ? LanguageCatalog.byCode(detected) ??
              Language(code: detected, name: detected)
        : source;
    return LanguageMatcher.match(wanted, state.targetLanguages) ?? wanted;
  }

  /// What a meaning check returned, for usage counting.
  static String _meaningText(MeaningCheck check) => [
    check.verdict.name,
    check.backTranslation,
    for (final issue in check.issues) ...[
      issue.sourceSpan,
      issue.translationSpan,
      issue.problem,
      issue.suggestion,
    ],
  ].join('\n');

  /// [base] without a meaning check.
  static TranslateState _clearedMeaning(TranslateState base) => base.copyWith(
    meaningStatus: ExtraStatus.idle,
    meaningCheck: () => null,
    backTranslation: () => null,
    meaningFocus: () => null,
    meaningError: () => null,
  );

  /// The detected source language was uncertain
  /// ([TranslateState.detectionUncertain]) and the user picked [code] (one
  /// of [TranslateState.detectedAlternatives]): selects that source
  /// language (as listed by the engine, saved like [setSource]) and
  /// translates again. Codes the engine does not list are ignored.
  ///
  /// When [code] is the target language, the target switches too (never a
  /// same-language translation): back to the target from before the last
  /// smart swap when that swap led here, else to the language a smart swap
  /// would choose (saved and recorded as recent). Nothing happens when
  /// there is no other target.
  void useDetectedAlternative(String code) {
    final language = LanguageMatcher.match(
      Language(code: code, name: code),
      state.sourceLanguages,
    );
    if (language == null || language.isAuto || language.isCustom) return;
    final normalized = LanguageMatcher.normalize(language.code);
    final target = state.target;
    if (target.isCustom ||
        normalized != LanguageMatcher.normalize(target.code)) {
      setSource(language);
      return;
    }
    final newTarget =
        _targetAfterSwapOf(normalized) ?? _targetOtherThan(normalized);
    if (newTarget == null || !_applySource(language)) return;
    _settings
      ..setLanguages(target: newTarget)
      ..addRecentLanguage(newTarget);
    emit(_clearedExtras(state).copyWith(source: language, target: newTarget));
    _retranslate();
  }

  /// The target from before the last smart swap when that swap set the
  /// current target and the previous one is not [code] (normalised), as
  /// the engine lists it; else null.
  Language? _targetAfterSwapOf(String code) {
    final swap = _lastSmartSwap;
    if (swap == null || state.target != swap.newTarget) return null;
    final previous = state.usableTarget(swap.previousTarget);
    if (previous == null ||
        previous.isCustom ||
        LanguageMatcher.normalize(previous.code) == code) {
      return null;
    }
    return previous;
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
    required String Function(T value) usageText,
    required TranslateState Function(TranslateState state, T value) ready,
    required TranslateState Function(TranslateState state) failed,
  }) async {
    final engine = state.assistEngine;
    final output = _completedOutput;
    if (engine == null || output == null) return;
    final token = _invalidateExtra(extra);
    emit(loading(state).copyWith(extraError: () => null));
    try {
      final request = _extrasRequest();
      final value = await fetch(engine, request, output);
      _recordUsage(
        engine,
        input: _extrasUsageInput(request, output),
        output: usageText(value),
      );
      if (!_isCurrentExtra(extra, token)) return;
      emit(ready(state, value));
    } on Object catch (error) {
      if (!_isCurrentExtra(extra, token)) return;
      emit(failed(state).copyWith(extraError: () => error));
    }
  }

  /// Counts a finished request to [engine]'s provider (engines with a
  /// `providerId`: AI and machine translation services) when a usage
  /// tracker is set. Never throws; tracker errors are ignored.
  void _recordUsage(
    TranslationEngine engine, {
    required String input,
    required String output,
  }) {
    final tracker = _usageTracker;
    final providerId = engine.providerId;
    if (tracker == null || providerId == null || providerId.isEmpty) return;
    try {
      unawaited(
        tracker
            .recordText(providerId, input: input, output: output)
            .then((_) {}, onError: (Object _) {}),
      );
    } on Object {
      // Usage counting must never break a translation.
    }
  }

  /// What an extras request sends besides the prompt: the source text, the
  /// translation and (explain) the question.
  static String _extrasUsageInput(
    TranslationRequest request,
    String translation, {
    String? question,
  }) => [request.text, translation, ?question].join('\n');

  static String _alternativesText(AlternativeTranslations value) => [
    value.description,
    for (final alternative in value.alternatives) ...[
      alternative.text,
      alternative.explanation,
    ],
  ].join('\n');

  static String _insightsText(List<WordInsight> insights) => [
    for (final insight in insights) ...[
      insight.sourceText,
      insight.targetText,
      insight.type,
      insight.explanation,
      for (final variation in insight.variations) ...[
        variation.text,
        variation.explanation,
      ],
    ],
  ].join('\n');

  static String _suggestionsText(List<RefinementSuggestion> suggestions) => [
    for (final suggestion in suggestions) ...[
      suggestion.label,
      suggestion.instruction,
      suggestion.description,
    ],
  ].join('\n');

  static String _dictionaryText(DictionaryEntry entry) => [
    entry.word,
    entry.pronunciation,
    ...entry.partsOfSpeech,
    for (final sense in entry.senses) ...[
      sense.definition,
      sense.partOfSpeech,
      ...sense.translations,
      sense.usage,
    ],
    for (final example in entry.examples) ...[
      example.source,
      example.translation,
    ],
    ...entry.synonyms,
    entry.etymology,
    entry.notes,
  ].join('\n');

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
    recentSourceLanguages: _recentSourceCodes(),
  );

  /// The aligned phrases (what the model listed), for usage counting.
  static String _alignmentText(
    List<AlignedSpan> spans,
    String source,
    String translation,
  ) {
    String slice(String text, int start, int end) {
      final from = math.min(start, text.length);
      return text.substring(from, math.max(from, math.min(end, text.length)));
    }

    return [
      for (final span in spans) ...[
        slice(source, span.sourceStart, span.sourceEnd),
        slice(translation, span.targetStart, span.targetEnd),
      ],
    ].join('\n');
  }

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
    if (extra == _Extra.refinement) _cancelRefinement();
    return _extraRequests[extra] = (_extraRequests[extra] ?? 0) + 1;
  }

  bool _isCurrentExtra(_Extra extra, int token) =>
      !isClosed && _extraRequests[extra] == token;

  /// [_isCurrentExtra], and the result is still the one [extra] was
  /// requested for.
  bool _isCurrentResultExtra(
    _Extra extra,
    int token,
    TranslationResult result,
  ) => _isCurrentExtra(extra, token) && state.result == result;

  /// Invalidates all in-flight extras (including a refinement) and returns
  /// [base] with every extra, the applied refinements, the romanization and
  /// the alignment reset.
  TranslateState _clearedExtras(TranslateState base) {
    _Extra.values.forEach(_invalidateExtra);
    return _clearedResultExtras(base).copyWith(
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
      dictionaryQuery: () => null,
      extraError: () => null,
      appliedRefinements: const [],
      pendingRefinement: () => null,
      refinementError: () => null,
    );
  }

  /// For a new output of the same input (refinements): invalidates and
  /// resets what was derived from the old output (alternatives, insights,
  /// explanation, romanization, alignment). Suggestions, the dictionary and
  /// the applied refinements stay.
  TranslateState _clearedOutputExtras(TranslateState base) {
    _invalidateExtra(_Extra.alternatives);
    _invalidateExtra(_Extra.insights);
    _invalidateExtra(_Extra.explain);
    return _clearedResultExtras(base).copyWith(
      alternativesStatus: ExtraStatus.idle,
      alternatives: () => null,
      alternativesSpan: () => null,
      alternativesSpanStart: () => null,
      insightsStatus: ExtraStatus.idle,
      insights: const [],
      explainStatus: ExtraStatus.idle,
      explanation: '',
      extraError: () => null,
    );
  }

  /// Invalidates and resets the romanization, the alignment and the
  /// meaning check (they belong to the current result).
  TranslateState _clearedResultExtras(TranslateState base) {
    _invalidateExtra(_Extra.romanization);
    _invalidateExtra(_Extra.alignment);
    _invalidateExtra(_Extra.meaning);
    return _clearedMeaning(base).copyWith(
      romanizationStatus: ExtraStatus.idle,
      romanization: () => null,
      romanizationError: () => null,
      alignmentStatus: ExtraStatus.idle,
      alignment: const [],
      alignmentFocus: () => null,
      alignmentError: () => null,
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
    _cancelRefinement();
    _withoutExtraTranslations(state);
    unawaited(_settingsSubscription.cancel());
    return super.close();
  }
}
