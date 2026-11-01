import 'dart:async';
import 'dart:math' as math;
import 'dart:ui' show PlatformDispatcher;

import 'package:bloc/bloc.dart';
import 'package:mozhi/core/network/network_policy.dart' show NetworkPolicyError;
import 'package:mozhi/core/on_device_ai_engine.dart';
import 'package:mozhi/history/cubit/history_cubit.dart';
import 'package:mozhi/history/data/translation_memory.dart';
import 'package:mozhi/history/models/history_entry.dart';
import 'package:mozhi/platform/device_conditions.dart';
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
/// * Typing ([setInput]) auto-translates when `instantTranslate` (machine
///   translation) / `instantTranslateAi` (AI) is on, after a pause that
///   suits the edit ([instantDelay]: none after a paste or the end of a
///   sentence, short after a word, longer within one), during which
///   [TranslateState.queued] is set; the previous result stays meanwhile.
///   Any new translation cancels the in-flight one (stream subscription
///   cancel). Typing does not start on-device AI while the phone is hot
///   or battery saver is on (`deviceConditions`, see [DeviceConditions]),
///   nor an on-device assistant's automatic romanization; Enter (also a
///   new line) and Translate still do.
/// * Text from outside the app ([setExternalInput]) is length-capped and
///   only auto-translated when that costs nothing (see there).
/// * Completed translations are added to `history` when `saveHistory` (and
///   not `incognito`).
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
///   "Fast" / "Best" in settings without changing the normal engine (a
///   mode without an engine of its own uses the normal one). Once both are
///   set up ([TranslateState.hasQualityModes]) one of them is always on:
///   a saved "usual engine" moves to a mode, and picking an engine makes
///   it the active mode's engine.
/// * [checkMeaning] checks, on demand, whether the output means the same as
///   the input (an AI check, or a back-translation with the main engine).
/// * Extra targets ([setExtraTargets], "Also translate into…") are
///   translated with every translation of the input, each with a request
///   of its own (same engine and options; never saved in history). They
///   are loaded from and saved to `AppSettings.extraTargets`; picks the
///   engine does not offer stay picked (and saved) but are not used
///   ([TranslateState.unavailableExtraTargets]).
/// * Translation memory: whenever the input or the languages change, the
///   history (`history`, when `saveHistory` is on, within the retention)
///   is searched for an earlier translation of the same or very similar
///   text into the same language (`memory`, see [TranslationMemory]);
///   [TranslateState.memoryMatch] offers it right away, before and while
///   the engine translates. It only becomes the output when the user picks
///   it ([useMemoryMatch]); it never replaces an engine translation by
///   itself, and an engine translation started later replaces it.
/// * Fallback: when the main translation's final result is suspect
///   (`TranslationResult.isSuspect`: the engine returned the original text,
///   the wrong language, garbage or a chat reply), up to
///   [maxFallbackEngines] other engines are tried in turn: the on-device
///   engine first, then engines that are not cloud providers and that the
///   privacy settings allow without a new consent
///   (`TranslationRepository.needsConsent`). Text that an engine on this
///   device translated (the offline engine, an on-device AI model) is
///   never sent to another engine by itself: its fallbacks stay on the
///   device too (the offline engine); comparing with another engine stays
///   the user's choice. On-device AI models are never fallbacks (they
///   would load a large model unasked). The first result that is not
///   suspect is shown with [TranslateState.fallback] ("Google returned the
///   original text. Translated on this device."); when none is, the
///   suspect result is shown with its warnings. The suspect result is
///   shown (unfinished) while the fallback runs.
/// * DuckDuckGo when Google fails (on by default, `AppSettings
///   .fallbackToDuckDuckGo`; see [duckDuckGoFallbackApplies]): a
///   translation with Mozhi's Google engine that failed on every volunteer
///   server ([AllInstancesFailedException]) is tried once more with Mozhi's
///   DuckDuckGo engine through the same servers (the pool's failover
///   included), main and extra targets alike. The request goes through
///   the repository's consent check like any DuckDuckGo request: a "Once"
///   given for Google does not cover it, so [TranslateState.consent] may
///   ask, naming DuckDuckGo, and the retry after consent goes straight to
///   DuckDuckGo. The result, its history entry, its destination chip and
///   the network log name DuckDuckGo, and [TranslateState.fallback] says
///   why ("Google failed on every server, so DuckDuckGo translated
///   this."). [useDuckDuckGoWhenGoogleFails] turns it on from the error.
/// * Offline first with the on-device engine the app picked by itself (no
///   engine chosen, see [onlineFallbackOf]): text the device can't
///   translate (its language is not downloaded) goes to the default online
///   engine instead, through the repository's consent check, so for a pair
///   the user has not allowed [TranslateState.consent] asks first
///   (`ConsentRequest.fromOnDevice`, with the language to download). The
///   result names the engine that translated.
/// * The personal data shield (`AppSettings.maskPersonalData`) is pushed to
///   the repository (`TranslationRepository.maskPersonalData`) from the
///   first [loadEngines] on.
/// * When a local AI engine becomes the selected one, its model is warmed
///   up (`TranslationRepository.warmUp`).
/// * A translation that fails after part of it arrived (the finished parts
///   of a long text, the text streamed so far) keeps that part as the
///   result, unfinished, next to the error.
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
    Duration? offlineDebounce,
    Duration? boundaryDebounce,
    Duration? aiBoundaryDebounce,
    Duration? aiSentenceDebounce,
    DateTime Function()? clock,
    List<String> Function()? deviceLanguages,
    this._usageTracker,
    TranslationMemory? memory,
    DeviceConditions? deviceConditions,
  }) : _settings = settings,
       _deviceConditions = deviceConditions ?? DeviceConditions.instance,
       offlineDebounce = _atMost(
         offlineDebounce ?? defaultOfflineDebounce,
         debounce,
       ),
       boundaryDebounce = _atMost(
         boundaryDebounce ?? defaultBoundaryDebounce,
         debounce,
       ),
       aiBoundaryDebounce = _atMost(
         aiBoundaryDebounce ?? defaultAiBoundaryDebounce,
         aiDebounce,
       ),
       aiSentenceDebounce = _atMost(
         aiSentenceDebounce ?? defaultAiSentenceDebounce,
         _atMost(aiBoundaryDebounce ?? defaultAiBoundaryDebounce, aiDebounce),
       ),
       _memory = memory ?? TranslationMemory(),
       _clock = clock ?? DateTime.now,
       _deviceLanguages = deviceLanguages ?? _platformLanguages,
       _seenExtraTargets = settings.state.extraTargets,
       super(
         TranslateState(
           source: settings.state.source,
           target: settings.state.target,
           options: settings.state.options,
           extraTargets: AppSettings.normalizeExtraTargets(
             settings.state.extraTargets,
           ),
         ),
       ) {
    _settingsSubscription = settings.stream.listen(_onSettings);
    _historySubscription = _history.stream.listen(_onHistory);
  }

  /// Most codes in [TranslationRequest.recentSourceLanguages].
  static const maxRecentSourceLanguages = 5;

  /// Default [offlineDebounce] (never longer than [debounce]): the
  /// on-device engine costs nothing and answers quickly.
  static const defaultOfflineDebounce = Duration(milliseconds: 250);

  /// Default [boundaryDebounce] (never longer than [debounce]).
  static const defaultBoundaryDebounce = Duration(milliseconds: 350);

  /// Default [aiBoundaryDebounce] (never longer than [aiDebounce]).
  static const defaultAiBoundaryDebounce = Duration(milliseconds: 600);

  /// Default [aiSentenceDebounce] (never longer than [aiBoundaryDebounce]).
  static const defaultAiSentenceDebounce = Duration(milliseconds: 300);

  /// Fewest characters a single edit inserts to count as a paste (see
  /// [instantDelay]); an edit that inserts several words counts too.
  static const pasteMinLength = 16;

  static Duration _atMost(Duration value, Duration limit) =>
      value < limit ? value : limit;

  /// Most engines tried after a suspect result (see the class
  /// documentation).
  static const maxFallbackEngines = 2;

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
  static const int maxExtraTargets = AppSettings.maxExtraTargets;

  /// Marks a model-generated suggestion instruction as a lower-trust
  /// refinement preference rather than a user instruction.
  static const refinementPrefix =
      'Refinement preference (from a suggestion chip):';

  static const _english = Language(code: 'en', name: 'English');
  static const _defaultEngineId = 'mozhi:google';

  /// The engine of the DuckDuckGo fallback ([duckDuckGoFallbackApplies]).
  static const duckDuckGoEngineId = 'mozhi:duckduckgo';

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

  /// Finds earlier translations of the input in the history.
  final TranslationMemory _memory;

  /// The phone's heat and battery saver: typing does not start on-device
  /// AI while it is strained ([_sparesDevice]).
  final DeviceConditions _deviceConditions;

  /// Ids of the history entries recorded since the input was last empty or
  /// replaced as a whole: they are translations of earlier versions of the
  /// text being typed, so they are not offered as similar text.
  final _typingEntryIds = <String>{};

  /// Whether [dismissMemoryMatch] hid the match for the current input and
  /// languages (a history change doesn't bring it back).
  bool _memoryDismissed = false;

  /// Instant-translate delay for machine translation engines (Mozhi, DeepL
  /// API, LibreTranslate) while a word is being typed.
  // Immutable configuration passed to the constructor, not state.
  // ignore: avoid_public_fields
  final Duration debounce;

  /// Instant-translate delay for AI engines while a word is being typed.
  // Immutable configuration passed to the constructor, not state.
  // ignore: avoid_public_fields
  final Duration aiDebounce;

  /// Instant-translate delay for the on-device engine
  /// ([defaultOfflineDebounce] unless [debounce] is shorter).
  // Immutable configuration passed to the constructor, not state.
  // ignore: avoid_public_fields
  final Duration offlineDebounce;

  /// Instant-translate delay for machine translation engines after a word
  /// ([defaultBoundaryDebounce] unless [debounce] is shorter).
  // Immutable configuration passed to the constructor, not state.
  // ignore: avoid_public_fields
  final Duration boundaryDebounce;

  /// Instant-translate delay for AI engines after a word
  /// ([defaultAiBoundaryDebounce] unless [aiDebounce] is shorter).
  // Immutable configuration passed to the constructor, not state.
  // ignore: avoid_public_fields
  final Duration aiBoundaryDebounce;

  /// Instant-translate delay for AI engines after the end of a sentence or
  /// a new line ([defaultAiSentenceDebounce] unless [aiBoundaryDebounce] is
  /// shorter): long enough that a sentence typed on is not sent twice.
  // Immutable configuration passed to the constructor, not state.
  // ignore: avoid_public_fields
  final Duration aiSentenceDebounce;

  /// The personal data shield last pushed to the repository (null before
  /// the first [loadEngines]).
  bool? _shieldPushed;

  /// The on-device pair last preloaded (`engine|source>target`), so that
  /// [onChange] asks for each pair once.
  String? _preloadedPair;

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

  /// The text of the last main translation started (see [_coveredText]).
  String? _requestText;

  /// The languages of the last finished main translation (or compare
  /// result used), see [_currentResultForCompare].
  ({Language source, Language target})? _resultLanguages;

  /// Translation requests stopped for consent ([TranslateState.consent]).
  int _consentRequests = 0;

  /// Runs the translation [TranslateState.consent] stopped again.
  Future<void> Function()? _consentRetry;

  /// The consent of the retry in flight ([retryAfterConsent]) and its main
  /// translation: the approval is withdrawn when that ends or is cancelled.
  ({ConsentRequiredException consent, Completer<void> main})? _retryConsent;

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

  /// `AppSettings.extraTargets` when the settings were last looked at
  /// ([_syncExtraTargets]).
  List<Language> _seenExtraTargets;

  late final StreamSubscription<AppSettings> _settingsSubscription;

  /// The history, for [TranslateState.memoryMatch] ([_onHistory]).
  late final StreamSubscription<HistoryState> _historySubscription;

  /// [TranslationRepository.metadataChanged], listened to from the first
  /// [loadEngines] on (null for repository test doubles without it).
  StreamSubscription<void>? _metadataSubscription;
  bool _metadataListened = false;

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
  Future<void> loadEngines({bool refresh = false}) =>
      _loadEngines(refresh: refresh);

  /// Reloads the engines quietly (without the loading state) when the
  /// Mozhi engine list could not be loaded last time
  /// ([TranslationRepository.mozhiEnginesNeedReload]: no network at launch,
  /// every server down), so that the Mozhi engines come back, e.g. when the
  /// app returns to the front. Does nothing otherwise, or while the engines
  /// load.
  Future<void> reloadEnginesIfNeeded() {
    if (_listPending || isClosed) return Future.value();
    bool needed;
    try {
      needed = _repository.mozhiEnginesNeedReload;
    } on Object {
      // A repository test double without it.
      needed = false;
    }
    if (!needed) return Future.value();
    return _loadEngines(quiet: true);
  }

  /// [loadEngines]; [quiet] neither shows the loading state nor reports a
  /// failure to list the engines (the lists shown stay).
  Future<void> _loadEngines({bool refresh = false, bool quiet = false}) async {
    if (!_metadataListened) {
      _metadataListened = true;
      _metadataSubscription = _listenToMetadata();
    }
    _pushShield(_settings.state);
    final request = ++_enginesRequest;
    final switches = _switches;
    _listPending = true;
    if (!quiet) emit(state.copyWith(enginesStatus: EnginesStatus.loading));
    final List<TranslationEngine> engines;
    try {
      engines = await _repository.getEngines(refresh: refresh);
    } on Object catch (error) {
      if (!_isCurrentEngines(request)) return;
      _listPending = false;
      if (quiet) return;
      emit(
        state.copyWith(
          enginesStatus: EnginesStatus.failure,
          error: () => error,
        ),
      );
      _runTranslateWhenReady(ready: false);
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
      _runTranslateWhenReady(ready: false);
      return;
    }

    // An engine the user picked while the list was loading wins; then the
    // engine of the saved quality mode (once Fast and Best are set up, a
    // user still on the usual engine moves to a mode, see
    // _savedQualityMode).
    final picked = _switches != switches ? state.engine : null;
    final (:fast, :best) = _resolveQuality(engines);
    final wanted = _savedQualityMode(engines, fast, best);
    final modeEngine = _qualityEngineOf(wanted, fast, best);
    final candidates = _engineCandidates(
      engines,
      preferred: picked ?? modeEngine,
    );
    if (candidates.isEmpty) {
      // The chosen engine is gone and nothing may replace it silently: the
      // user picks one (the engine list is shown).
      _languagesRequest++;
      _cancelTranslation();
      emit(
        _clearedExtras(_withoutExtraTranslations(state)).copyWith(
          enginesStatus: EnginesStatus.ready,
          engines: engines,
          engine: () => null,
          assistEngine: () => null,
          status: TranslateStatus.idle,
          result: () => null,
          error: () => null,
          qualityMode: QualityMode.off,
          fastEngine: () => fast,
          bestEngine: () => best,
        ),
      );
      _runTranslateWhenReady(ready: false);
      return;
    }
    final languagesRequest = ++_languagesRequest;
    final loaded = await _loadFirstUsable(
      candidates,
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
          fastEngine: () => fast,
          bestEngine: () => best,
        ),
      );
      // The engine picked meanwhile translates the input itself.
      _runTranslateWhenReady(ready: false);
      return;
    }

    final engine = loaded.engine;
    final mode = _modeOf(engine, wanted, fast, best);
    final changed = engine.id != state.engine?.id;
    if (changed) {
      _cancelTranslation();
      _warmUp(engine);
    }
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
      _runTranslateWhenReady(ready: false);
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

    // Translate was pressed while the engines loaded: now.
    if (_runTranslateWhenReady(ready: true)) return;
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
  /// Without Fast and Best set up ([TranslateState.hasQualityModes]),
  /// choosing an engine turns quality mode off (also when [engine] is the
  /// quality mode's engine: it becomes the normal engine). Once they are
  /// set up one of them is always on: [engine] becomes the engine of the
  /// active mode (the engine sheet's "Custom engine…"), or that other mode
  /// is selected when [engine] is its engine (see [_assignToMode]).
  Future<void> selectEngine(TranslationEngine engine) async {
    if (_assignToMode(engine)) {
      if (engine.id == state.engine?.id &&
          state.enginesStatus == EnginesStatus.ready) {
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
      return;
    }
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
    _warmUp(engine);
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
  ///   [TranslateState.fastEngine] / [TranslateState.bestEngine] (see
  ///   [_resolveQuality]) when that engine is available; otherwise nothing
  ///   changes (see [TranslateState.availableQualityModes]).
  ///   Turning a mode on from [QualityMode.off] remembers the engine in use
  ///   (and saves it as the normal engine when settings name none).
  /// * [QualityMode.off] returns to the normal engine: `AppSettings.engineId`
  ///   when available, else the engine in use before the mode was turned
  ///   on, else the default (or first) engine other than the mode's. Once
  ///   Fast and Best are set up ([TranslateState.hasQualityModes]) one of
  ///   them is always on, and [QualityMode.off] (a link's "standard") means
  ///   [QualityMode.fast].
  ///
  /// The mode is saved (`SettingsCubit.setQualityMode`) unless [persist]
  /// is false (a mode a link asked for: it lasts until the app restarts or
  /// the user picks a mode or an engine). After an engine switch the input
  /// is translated again like after [selectEngine] (never in compare mode).
  /// [selectEngine] turns the mode off while Fast and Best are not set up.
  Future<void> setQualityMode(QualityMode mode, {bool persist = true}) async {
    final wanted = mode == QualityMode.off && state.hasQualityModes
        ? QualityMode.fast
        : mode;
    final TranslationEngine? engine;
    if (wanted == QualityMode.off) {
      // Already on the normal engine: only the saved mode may differ.
      engine = state.qualityMode == QualityMode.off ? null : _normalEngine();
    } else {
      engine = state.qualityEngine(wanted);
      if (engine == null) return;
      final current = state.engine;
      if (state.qualityMode == QualityMode.off && current != null) {
        _engineBeforeQuality = current.id;
        // A fallback engine (none was ever picked) becomes the one to go
        // back to after a restart too.
        if (_settings.state.engineId == null) _settings.setEngine(current.id);
      }
    }
    if (wanted == QualityMode.off) _engineBeforeQuality = null;
    if (persist && _settings.state.qualityMode != wanted) {
      _settings.setQualityMode(wanted);
    }
    if (state.qualityMode != wanted) emit(state.copyWith(qualityMode: wanted));
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

  /// While Fast and Best are set up and a mode is on, makes [engine] the
  /// engine of that mode and returns true (false otherwise: the caller
  /// handles the pick as a normal engine).
  ///
  /// [engine] is the other mode's engine: that mode is selected. Otherwise
  /// it is saved as the active mode's engine (`SettingsCubit
  /// .setQualityEngines`), or as the usual engine (`SettingsCubit
  /// .setEngine`) when the mode has no engine of its own and uses the
  /// usual one. The mode is saved. The caller switches to [engine].
  bool _assignToMode(TranslationEngine engine) {
    final active = state.qualityMode;
    if (!state.hasQualityModes || active == QualityMode.off) return false;
    final other = active == QualityMode.fast
        ? QualityMode.best
        : QualityMode.fast;
    final mode = state.qualityEngine(other)?.id == engine.id ? other : active;
    if (mode == active && state.qualityEngine(active)?.id != engine.id) {
      final settings = _settings.state;
      final own = active == QualityMode.fast
          ? settings.fastEngineId
          : settings.bestEngineId;
      if (own == null) {
        _settings.setEngine(engine.id);
      } else {
        _settings.setQualityEngines(
          fast: active == QualityMode.fast ? engine.id : settings.fastEngineId,
          best: active == QualityMode.best ? engine.id : settings.bestEngineId,
        );
      }
    }
    if (_settings.state.qualityMode != mode) _settings.setQualityMode(mode);
    emit(
      state.copyWith(
        qualityMode: mode,
        fastEngine: mode == QualityMode.fast ? () => engine : null,
        bestEngine: mode == QualityMode.best ? () => engine : null,
      ),
    );
    return true;
  }

  /// The engine [QualityMode.off] switches to: the saved normal engine
  /// (`AppSettings.engineId`), else the one in use before the quality mode
  /// was turned on, else the on-device engine, the default engine or the
  /// first engine that is not a cloud provider, other than the current one
  /// (the quality mode's), so that turning a mode off never keeps
  /// translating with its engine while another one is available (and never
  /// picks a cloud provider by itself).
  TranslationEngine? _normalEngine() {
    final engines = state.engines;
    final saved =
        _engineIn(engines, _settings.state.engineId) ??
        _engineIn(engines, _engineBeforeQuality);
    if (saved != null) return saved;
    final current = state.engine?.id;
    for (final engine in [
      engines.where((e) => e.isOffline).firstOrNull,
      _engineIn(engines, _defaultEngineId),
      ...engines.where((e) => !_isCloudEngine(e)),
    ]) {
      if (engine != null && engine.id != current) return engine;
    }
    return null;
  }

  /// The usual engine among [engines]: the saved normal engine
  /// (`AppSettings.engineId`), else the one in use before a quality mode
  /// was turned on, else the engine the app picks by itself (the on-device
  /// engine unless the privacy mode is online, the default engine, the
  /// first engine that is not a cloud provider).
  TranslationEngine? _usualEngineIn(List<TranslationEngine> engines) {
    final settings = _settings.state;
    final online = settings.privacyMode == PrivacyMode.online;
    for (final engine in [
      _engineIn(engines, settings.engineId),
      _engineIn(engines, _engineBeforeQuality),
      if (!online) engines.where((e) => e.isOffline).firstOrNull,
      _engineIn(engines, _defaultEngineId),
      engines.where((e) => !_isCloudEngine(e)).firstOrNull,
    ]) {
      if (engine != null) return engine;
    }
    return null;
  }

  /// The Fast and Best engines among [engines]: a mode's own engine
  /// (`AppSettings.fastEngineId` / `bestEngineId`) when it is available. A
  /// mode without an engine of its own uses the usual engine
  /// ([_usualEngineIn]) as long as the other mode has one, so that picking
  /// only a Best engine gives "Fast = the usual engine | Best". When that
  /// makes both modes the same engine, only their own engines are kept (the
  /// modes are not set up, see [TranslateState.hasQualityModes]).
  ({TranslationEngine? fast, TranslationEngine? best}) _resolveQuality(
    List<TranslationEngine> engines,
  ) {
    final settings = _settings.state;
    final fast = _engineIn(engines, settings.fastEngineId);
    final best = _engineIn(engines, settings.bestEngineId);
    if (fast == null && best == null) return (fast: null, best: null);
    final usual = _usualEngineIn(engines);
    final resolvedFast = fast ?? (settings.fastEngineId == null ? usual : null);
    final resolvedBest = best ?? (settings.bestEngineId == null ? usual : null);
    if (resolvedFast?.id == resolvedBest?.id) return (fast: fast, best: best);
    return (fast: resolvedFast, best: resolvedBest);
  }

  /// The saved quality mode (`AppSettings.qualityMode`). Once Fast and Best
  /// are set up ([fast] and [best], two different engines) one of them is
  /// always on: a saved [QualityMode.off] (the usual engine, from before)
  /// becomes the mode whose engine the usual engine is, else Fast, and that
  /// is saved.
  QualityMode _savedQualityMode(
    List<TranslationEngine> engines,
    TranslationEngine? fast,
    TranslationEngine? best,
  ) {
    final saved = _settings.state.qualityMode;
    if (saved != QualityMode.off || !_isSetUp(fast, best)) return saved;
    final usual = _usualEngineIn(engines)?.id;
    final mode = usual == best!.id && usual != fast!.id
        ? QualityMode.best
        : QualityMode.fast;
    _settings.setQualityMode(mode);
    return mode;
  }

  /// Whether [fast] and [best] set the quality modes up (two different
  /// engines, see [TranslateState.hasQualityModes]).
  static bool _isSetUp(TranslationEngine? fast, TranslationEngine? best) =>
      fast != null && best != null && fast.id != best.id;

  /// [fast] or [best] for [mode] (null for [QualityMode.off]).
  static TranslationEngine? _qualityEngineOf(
    QualityMode mode,
    TranslationEngine? fast,
    TranslationEngine? best,
  ) => switch (mode) {
    QualityMode.off => null,
    QualityMode.fast => fast,
    QualityMode.best => best,
  };

  /// The mode [engine] translates in: [wanted] when [engine] is its engine;
  /// while Fast and Best are set up, the mode whose engine [engine] is;
  /// else [QualityMode.off].
  static QualityMode _modeOf(
    TranslationEngine engine,
    QualityMode wanted,
    TranslationEngine? fast,
    TranslationEngine? best,
  ) {
    if (wanted != QualityMode.off &&
        _qualityEngineOf(wanted, fast, best)?.id == engine.id) {
      return wanted;
    }
    if (_isSetUp(fast, best)) {
      if (engine.id == fast!.id) return QualityMode.fast;
      if (engine.id == best!.id) return QualityMode.best;
    }
    return QualityMode.off;
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
  /// sync with the settings ([_resolveQuality]). When the engine of the
  /// active mode changes it is switched to (keeping the output); when it is
  /// removed the mode is turned off and the normal engine comes back. When
  /// Fast and Best become set up while no mode is on, a mode is turned on
  /// ([_savedQualityMode]).
  ///
  /// Extra targets saved by someone else are applied too
  /// ([_syncExtraTargets]).
  void _onSettings(AppSettings settings) {
    _syncExtraTargets();
    if (_shieldPushed != null) _pushShield(settings);
    if (!settings.saveHistory && state.memoryMatch != null && !isClosed) {
      emit(state.copyWith(memoryMatch: () => null));
    }
    if (isClosed || state.engines.isEmpty) return;
    final (:fast, :best) = _resolveQuality(state.engines);
    final changed = fast != state.fastEngine || best != state.bestEngine;
    if (changed) {
      emit(state.copyWith(fastEngine: () => fast, bestEngine: () => best));
    }
    // An engine list load applies the mode itself.
    if (_listPending || state.enginesStatus != EnginesStatus.ready) return;
    var mode = state.qualityMode;
    if (mode == QualityMode.off) {
      if (!_isSetUp(fast, best)) return;
      mode = _savedQualityMode(state.engines, fast, best);
      if (mode == QualityMode.off) mode = QualityMode.fast;
      emit(state.copyWith(qualityMode: mode));
    } else if (!changed) {
      return;
    }
    var engine = _qualityEngineOf(mode, fast, best);
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

  /// Loads the model of a local AI [engine] (Ollama, LM Studio, ...) in
  /// the background (`TranslationRepository.warmUp`), so that the first
  /// translation does not wait for it. Errors are ignored.
  void _warmUp(TranslationEngine engine) {
    if (!engine.isAi || !engine.isLocal) return;
    try {
      unawaited(
        _repository.warmUp(engine).then((_) {}, onError: (Object _) {}),
      );
    } on Object {
      // A repository test double without warm-up.
    }
  }

  @override
  void onChange(Change<TranslateState> change) {
    super.onChange(change);
    _preloadOffline(change.nextState);
  }

  /// Loads the on-device models of the current pair in the background
  /// (`TranslationRepository.preloadOffline`) once the on-device engine is
  /// selected with a known source language, so that the first translation
  /// doesn't wait for them. Errors are ignored.
  void _preloadOffline(TranslateState state) {
    final engine = state.engine;
    if (engine == null || !engine.isOffline || state.source.isAuto) return;
    final pair = '${engine.id}|${state.source.code}>${state.target.code}';
    if (pair == _preloadedPair) return;
    _preloadedPair = pair;
    try {
      unawaited(
        _repository
            .preloadOffline(engine, source: state.source, target: state.target)
            .then((_) {}, onError: (Object _) {}),
      );
    } on Object {
      // A repository test double without preloading.
    }
  }

  /// Pushes `AppSettings.maskPersonalData` to the repository when it
  /// changed.
  void _pushShield(AppSettings settings) {
    final mask = settings.maskPersonalData;
    if (_shieldPushed == mask) return;
    _shieldPushed = mask;
    try {
      _repository.maskPersonalData = mask;
    } on Object {
      // A repository test double without the shield.
    }
  }

  /// Persisted engine or language lists were served at start and the
  /// repository has since loaded different ones: reload the lists
  /// (from memory, without the loading state).
  StreamSubscription<void>? _listenToMetadata() {
    final Stream<void> changes;
    try {
      changes = _repository.metadataChanged;
    } on Object {
      // A repository test double without the stream.
      return null;
    }
    return changes.listen((_) => unawaited(_loadEngines(quiet: true)));
  }

  bool _isCurrentEngines(int request) =>
      !isClosed && request == _enginesRequest;

  bool _isCurrentLanguages(int request) =>
      !isClosed && request == _languagesRequest;

  /// Engines to try, best first: [preferred], the saved engine and the
  /// current one. Text never moves to another destination by itself, so
  /// the only fallback after them (an engine that is gone, or whose
  /// languages fail to load) is the on-device engine. Only when nothing was
  /// chosen yet (no saved engine) is a default picked: the on-device engine
  /// first unless the privacy mode is online, then [_defaultEngineId] (a
  /// Mozhi engine), then the first engine that is not a cloud provider
  /// (never a cloud AI or DeepL, which the user must pick). May be empty:
  /// the user then picks an engine.
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

    final offline = engines.where((e) => e.isOffline).firstOrNull;
    final saved = _settings.state.engineId;
    final online = _settings.state.privacyMode == PrivacyMode.online;
    final candidates = <TranslationEngine>[];
    for (final engine in [
      byId(preferred?.id),
      byId(saved),
      byId(state.engine?.id),
      if (saved == null) ...[
        if (!online) offline,
        byId(_defaultEngineId),
        engines.where((e) => !_isCloudEngine(e)).firstOrNull,
      ],
      offline,
    ]) {
      if (engine != null && candidates.every((e) => e.id != engine.id)) {
        candidates.add(engine);
      }
    }
    return candidates;
  }

  /// Whether [engine] sends text to a cloud provider (AI providers and
  /// machine translation services that are not local, DeepL).
  bool _isCloudEngine(TranslationEngine engine) {
    try {
      return _repository.destinationOf(engine.id) is CloudProviderDestination;
    } on Object {
      // Unknown (or a repository test double): judge by the engine.
      return (engine.isAi || engine.isMt) && !engine.isLocal;
    }
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

  /// The engine of the AI extras for [engine] out of [engines]: [engine]
  /// itself when it is an AI engine with extras (the text goes there
  /// anyway); else the configured assist engine
  /// ([AppSettings.assistEngineId]) when it has extras, unless Offline
  /// only keeps its text from leaving the device; else, when [engine]
  /// keeps the text on the device or the privacy mode is not online, the
  /// first engine with extras that does so too (an on-device assistant
  /// model); else the first AI engine with extras. Without any AI engine
  /// with extras: [engine] if it is an AI engine, the configured one or
  /// the first AI engine.
  TranslationEngine? _pickAssistEngine(
    TranslationEngine engine,
    List<TranslationEngine> engines,
  ) {
    if (engine.isAi && engine.supportsExtras) return engine;
    final ai = engines.where((e) => e.isAi).toList();
    final configured = _settings.state.assistEngineId;
    final mode = _settings.state.privacyMode;
    final capable = ai.where((e) => e.supportsExtras).toList();
    for (final candidate in capable) {
      if (candidate.id != configured) continue;
      if (mode != PrivacyMode.offlineOnly || _staysOnDevice(candidate)) {
        return candidate;
      }
    }
    if (_staysOnDevice(engine) || mode != PrivacyMode.online) {
      final onDevice = capable.where(_staysOnDevice).firstOrNull;
      if (onDevice != null) return onDevice;
    }
    if (capable.isNotEmpty) return capable.first;
    if (engine.isAi) return engine;
    for (final candidate in ai) {
      if (candidate.id == configured) return candidate;
    }
    return ai.firstOrNull;
  }

  /// Whether the text of [engine] stays on this device (the offline
  /// engine, on-device AI models).
  bool _staysOnDevice(TranslationEngine engine) {
    try {
      return _repository.destinationOf(engine.id).isOnDevice;
    } on Object {
      // Unknown (or a repository test double): judge by the engine.
      return engine.isOnDevice || isOnDeviceAiEngine(engine);
    }
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

    // The extra targets stay as picked: the ones this engine does not offer
    // are not used (TranslateState.activeExtraTargets) until one does.
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
  ///
  /// With instant translation on, the text is translated after the pause
  /// [instantDelay] picks for the edit: [pasted] marks a paste (the paste
  /// button, the field's Paste), [dictated] text from voice input (never
  /// taken for a paste, however much arrives at once).
  void setInput(String text, {bool pasted = false, bool dictated = false}) {
    _externalPending = false;
    _applyInput(
      text,
      maxLength: maxInputLength,
      instant: true,
      pasted: pasted,
      dictated: dictated,
    );
  }

  /// Puts [text], the input the app had when it last went to the
  /// background (`TranslateDraftKeeper`), back into the input after the app
  /// was ended. Only into an empty input that nothing from outside the app
  /// is waiting in (a share, a link or an intent wins); it is not
  /// translated right away. Returns whether it was put back.
  bool restoreDraft(String text) {
    if (isClosed ||
        text.trim().isEmpty ||
        state.input.isNotEmpty ||
        _externalPending) {
      return false;
    }
    _applyInput(text, maxLength: maxInputLength, instant: false);
    return true;
  }

  /// Replaces input and translates immediately (history, user actions).
  ///
  /// With [external] (share intents, PROCESS_TEXT, deep links, clipboard
  /// monitors) this is [setExternalInput], which may not translate.
  void setInputAndTranslate(String text, {bool external = false}) {
    if (external) return setExternalInput(text);
    _typingEntryIds.clear();
    setInput(text);
    unawaited(translate());
  }

  /// Opens the translation [entry] of the on-device history (the History
  /// tab): its languages, each mapped onto the engine's lists like
  /// [applyLanguagePair] (one the engine does not offer, or a custom
  /// language it cannot take, keeps the current one) and saved like a pick,
  /// and its text as the input, in one state change; then the text is
  /// translated once (the old input is not translated again on the way).
  /// Dictionary look-ups and empty entries are ignored (the History tab
  /// opens look-ups in the Dictionary).
  void openHistoryEntry(HistoryEntry entry) {
    if (entry.isDictionary || entry.text.trim().isEmpty) return;
    final source = _usableSource(entry.source);
    final target = _usableTarget(entry.target);
    final newSource = source != null && _applySource(source) ? source : null;
    final newTarget = target != null && _applyTarget(target) ? target : null;
    _debounceTimer?.cancel();
    _cancelTranslation();
    _cancelCompare();
    _externalPending = false;
    _typingEntryIds.clear();
    final input = entry.text.length > maxInputLength
        ? _truncate(entry.text, maxInputLength)
        : entry.text;
    final previous = state;
    emit(
      _clearedExtras(state).copyWith(
        source: newSource,
        target: newTarget,
        input: input,
        inputTruncated: input.length != entry.text.length,
        compareEntries: const [],
        comparing: false,
        compareBaseline: () => null,
        // A result kept until the translation arrives belongs to the
        // previous text.
        resultInput: previous.result != null && previous.resultInput == null
            ? () => previous.input
            : null,
      ),
    );
    unawaited(translate());
  }

  /// Shows the translation [entry] of the on-device history again (the
  /// empty screen's "Continue"): its languages (saved like a pick), its
  /// text as the input and its translation as the output, marked as coming
  /// from the history ([TranslateState.resultFromMemory]). Nothing is sent
  /// to an engine, counted or recorded again; Translate makes a fresh
  /// translation.
  ///
  /// Returns false (and changes nothing) for a dictionary look-up, without
  /// an engine, in compare mode, or when the engine does not offer one of
  /// the entry's languages.
  bool restoreHistoryEntry(HistoryEntry entry) {
    if (entry.isDictionary ||
        entry.text.trim().isEmpty ||
        state.engine == null ||
        state.compareMode) {
      return false;
    }
    final source = _usableSource(entry.source);
    final target = _usableTarget(entry.target);
    if (source == null || target == null) return false;
    _debounceTimer?.cancel();
    _cancelTranslation();
    _cancelCompare();
    _externalPending = false;
    _typingEntryIds.clear();
    _applySource(source);
    _applyTarget(target);
    final input = entry.text.length > maxInputLength
        ? _truncate(entry.text, maxInputLength)
        : entry.text;
    emit(
      _clearedExtras(_withoutExtraTranslations(state)).copyWith(
        source: source,
        target: target,
        input: input,
        inputTruncated: input.length != entry.text.length,
        result: () => TranslationResult(
          engineId: entry.engineId,
          engineName: entry.engineName,
          text: entry.translation,
          detectedSource: entry.detectedSource,
          fromCache: true,
        ),
        resultInput: () => input,
        resultFromMemory: true,
        // Not asked of an engine: paid extras are not started on their own.
        instantResult: true,
        status: TranslateStatus.success,
        error: () => null,
      ),
    );
    _autoRomanize();
    return true;
  }

  /// Puts text that came from outside the app into the input.
  ///
  /// * The text is cut to [maxExternalInputLength] (`inputTruncated`).
  /// * The same text arriving again within [externalRepeatWindow] is
  ///   ignored.
  /// * [source] and [target] (e.g. from a link) are applied first, as by
  ///   [setSource]/[setTarget] but without re-translating the old input.
  /// * It is translated right away only when that costs nothing: Mozhi (and
  ///   other non-AI) engines. AI engines wait for the user to press
  ///   Translate, even with `instantTranslateAi` on (that covers typing
  ///   only), so a link or share never starts a paid request on its own.
  ///   Compare mode never starts on its own either. In
  ///   [PrivacyMode.offlineOnly] only an engine that keeps the text on this
  ///   device starts on its own, and while the engines load the text waits
  ///   for them ([loadEngines] translates it with the engine it picks).
  void setExternalInput(String text, {Language? source, Language? target}) {
    final now = _clock();
    final last = _lastExternal;
    if (last != null &&
        last.text == text &&
        now.difference(last.at).abs() < externalRepeatWindow) {
      return;
    }
    _lastExternal = (text: text, at: now);
    _typingEntryIds.clear();
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

  /// Whether external input may be translated without a user action: only
  /// by engines that are not AI models, not while the engines (re)load
  /// (the engine may still change: [loadEngines] translates it once they
  /// are ready), and in [PrivacyMode.offlineOnly] only by an engine that
  /// keeps the text on this device.
  bool get _mayAutoTranslateExternal {
    final engine = state.engine;
    if (engine == null || state.compareMode || engine.isAi) return false;
    if (state.enginesStatus == EnginesStatus.loading) return false;
    return _settings.state.privacyMode != PrivacyMode.offlineOnly ||
        _staysOnDevice(engine);
  }

  /// Puts [raw] (cut to [maxLength]) into the input. With [instant] (typed
  /// or pasted text) and instant translation on for the engine, schedules
  /// its translation after [instantDelay] ([TranslateState.queued] until
  /// it starts); not when only white space at the end changed and the
  /// result (or the translation in flight) is of the same text otherwise.
  void _applyInput(
    String raw, {
    required int maxLength,
    required bool instant,
    bool pasted = false,
    bool dictated = false,
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
          compareBaseline: () => null,
        ),
      );
      return;
    }
    final previous = state;
    // Only white space at the end changed: what the result (or the
    // translation in flight) was made for still is the text.
    final covered = _coveredText(previous);
    final same = covered != null && covered.trimRight() == text.trimRight();
    final engine = state.engine;
    // A new line is the Enter key: it translates even while typing spares
    // the device.
    late final enter = _insertion(previous.input, text) == '\n';
    if (instant &&
        !same &&
        engine != null &&
        !state.compareMode &&
        (engine.isAi
            ? _settings.state.instantTranslateAi
            : _settings.state.instantTranslate) &&
        (!_sparesDevice(engine) || enter)) {
      // Scheduled before the input is emitted, so that it is queued.
      _debounceTimer = Timer(
        instantDelay(
          engine,
          previous.input,
          text,
          pasted: pasted,
          dictated: dictated,
        ),
        () => _translateInstantly(enter: enter),
      );
    }
    emit(
      _clearedExtras(state).copyWith(
        input: text,
        inputTruncated: truncated,
        compareEntries: const [],
        comparing: false,
        compareBaseline: () => null,
        resultInput: same && previous.status != TranslateStatus.translating
            ? () => text
            // The kept result belongs to the previous text.
            : previous.result != null && previous.resultInput == null
            ? () => previous.input
            : null,
      ),
    );
  }

  /// The text the shown result was made for when it is finished, or that
  /// of the main translation in flight; else null.
  String? _coveredText(TranslateState state) {
    if (state.status == TranslateStatus.translating) return _requestText;
    final result = state.result;
    if (result == null || !result.isComplete) return null;
    return state.resultInput ?? state.input;
  }

  /// The instant translation [_applyInput] scheduled is due ([enter]: for
  /// a new line, the Enter key).
  void _translateInstantly({required bool enter}) {
    // The phone got hot, or battery saver came on, while it waited.
    final engine = state.engine;
    if (!enter && engine != null && _sparesDevice(engine)) {
      if (state.queued) emit(state);
      return;
    }
    final translation = _translate(auto: true);
    // Nothing started (no engine any more): nothing is queued either.
    if (state.queued) emit(state);
    unawaited(translation);
  }

  /// Whether typing does not start [engine], to spare the device:
  /// on-device AI while the phone is hot or battery saver is on
  /// ([DeviceConditions]). The Enter key and the go button still translate.
  bool _sparesDevice(TranslationEngine engine) =>
      isOnDeviceAiEngine(engine) && _deviceConditions.latest.strain != null;

  /// How long an instant translation of [next] (the input after
  /// [previous]) waits with [engine]:
  ///
  /// * a paste ([pasted], or [isPasteLike] unless [dictated]): no wait;
  /// * the end of a sentence just typed ([endsSentence]) or a new line
  ///   (Enter): no wait for machine translation and the on-device engine;
  ///   [aiSentenceDebounce] for AI engines, so that a sentence typed on
  ///   right away is not sent twice;
  /// * after a word (white space or punctuation at the end):
  ///   [boundaryDebounce], [aiBoundaryDebounce] for AI engines and the
  ///   DeepL API (billed by the character, and every request sends the
  ///   whole text);
  /// * within a word: [debounce], [aiDebounce] for AI engines.
  ///
  /// The on-device engine waits [offlineDebounce] at most. Typing at a
  /// normal pace never sends more requests to AI engines than one after
  /// the last key: [aiBoundaryDebounce] is longer than the pause between
  /// two words. The DeepL API waits as long as before the shorter waits
  /// after a word came in, except after a paste or at a sentence end.
  Duration instantDelay(
    TranslationEngine engine,
    String previous,
    String next, {
    bool pasted = false,
    bool dictated = false,
  }) {
    if (!dictated && (pasted || isPasteLike(previous, next))) {
      return Duration.zero;
    }
    final ai = engine.isAi;
    final metered = ai || engine.mtService == MtService.deepl;
    final inserted = _insertion(previous, next);
    if ((endsSentence(next) && !endsSentence(previous)) || inserted == '\n') {
      return metered ? aiSentenceDebounce : Duration.zero;
    }
    final Duration delay;
    if (_wordEnd.hasMatch(next)) {
      delay = metered ? aiBoundaryDebounce : boundaryDebounce;
    } else {
      delay = ai ? aiDebounce : debounce;
    }
    return engine.isOffline ? _atMost(delay, offlineDebounce) : delay;
  }

  static final _sentenceEnd = RegExp(
    '[.?!…。？！؟۔।॥]'
    '["\'”’»)\\]」』]*\$',
  );

  static final _wordEnd = RegExp(r'[\s\p{P}]$', unicode: true);

  /// Whether [text] ends a sentence: `. ? ! …`, the CJK full stop and
  /// marks (`。？！`), the Arabic question mark and Urdu full stop
  /// (`؟ ۔`) or the Devanagari danda (`। ॥`), maybe followed by closing
  /// quotes or brackets.
  static bool endsSentence(String text) => _sentenceEnd.hasMatch(text);

  /// Whether going from [previous] to [next] looks like a paste rather than
  /// typing: one edit inserts at least [pasteMinLength] characters or
  /// several words (a keyboard's word suggestion or swipe inserts one).
  static bool isPasteLike(String previous, String next) {
    final inserted =
        (_insertion(previous, next) ?? _replacement(previous, next)).trim();
    return inserted.length >= pasteMinLength ||
        inserted.contains(RegExp(r'\s'));
  }

  /// What one edit from [previous] to [next] inserted, or null when it also
  /// removed text.
  static String? _insertion(String previous, String next) {
    final (start, end) = _changedRange(previous, next);
    if (start + end < previous.length) return null;
    return next.substring(start, next.length - end);
  }

  /// What one edit from [previous] to [next] put in place of the text it
  /// removed (or inserted).
  static String _replacement(String previous, String next) {
    final (start, end) = _changedRange(previous, next);
    return next.substring(start, next.length - end);
  }

  /// Lengths of the common prefix and (not overlapping it) suffix of
  /// [previous] and [next].
  static (int, int) _changedRange(String previous, String next) {
    final shorter = math.min(previous.length, next.length);
    var start = 0;
    while (start < shorter &&
        previous.codeUnitAt(start) == next.codeUnitAt(start)) {
      start++;
    }
    var end = 0;
    while (end < shorter - start &&
        previous.codeUnitAt(previous.length - 1 - end) ==
            next.codeUnitAt(next.length - 1 - end)) {
      end++;
    }
    return (start, end);
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
        compareBaseline: () => null,
      ),
    );
    unawaited(_translateAgain());
  }

  /// Saves [options] (without one-off instructions) for every engine, also
  /// one that does not apply them (they apply once an engine that does is
  /// used), and translates again right away when the current engine
  /// applies a changed option ([optionsChangeApplies]).
  void setOptions(TranslationOptions options) {
    final persisted = options.copyWith(instructions: '');
    final previous = state.options;
    if (persisted == previous) return;
    _settings.setOptions(persisted);
    emit(_clearedExtras(state).copyWith(options: persisted));
    final engine = state.engine;
    if (engine != null && optionsChangeApplies(engine, previous, persisted)) {
      _retranslate();
    }
  }

  /// Whether [engine] translates differently with [next] than with
  /// [previous]: AI engines with the general profile apply every option,
  /// DeepL (`TranslationEngine.supportsFormality`) the formality, the
  /// context and the formatting; other engines none.
  static bool optionsChangeApplies(
    TranslationEngine engine,
    TranslationOptions previous,
    TranslationOptions next,
  ) {
    if (engine.supportsOptions) return previous != next;
    if (!engine.supportsFormality) return false;
    return previous.formality != next.formality ||
        previous.context.trim() != next.context.trim() ||
        previous.preserveFormatting != next.preserveFormatting;
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
        compareBaseline: () => null,
      ),
    );
  }

  /// Re-translates right away (not debounced) when there is input.
  void _retranslate() {
    _debounceTimer?.cancel();
    if (state.input.trim().isEmpty) return;
    unawaited(_translateAgain());
  }

  // ---------------------------------------------------------------------
  // Translation
  // ---------------------------------------------------------------------

  /// Translate now (button / Ctrl+Enter). In compare mode this runs
  /// [runCompare] instead.
  ///
  /// The future completes when the translation finished, failed or was
  /// superseded.
  ///
  /// When the privacy settings stop it, [TranslateState.consent] asks for
  /// the user's consent with a dialog (`ConsentRequest.automatic` is false):
  /// the user asked for this translation. Translations started otherwise
  /// (instant translation, a language or engine change, a swap) only show
  /// the inline prompt.
  Future<void> translate() {
    _debounceTimer?.cancel();
    if (state.engine == null &&
        state.input.trim().isNotEmpty &&
        state.enginesStatus == EnginesStatus.loading) {
      // The engines are still loading: translate once one is ready
      // ([_loadEngines]) instead of dropping the press.
      return (_translateWhenReady ??= Completer<void>()).future;
    }
    if (state.compareMode) return runCompare();
    return _translate(userAsked: true);
  }

  /// [translate] was asked for while the engines were loading: completed
  /// once the translation it then starts finishes (or the engines failed).
  Completer<void>? _translateWhenReady;

  /// Runs the translation [translate] kept for the engines ([ready]), or
  /// lets it go when they failed. Returns whether one ran.
  bool _runTranslateWhenReady({required bool ready}) {
    final pending = _translateWhenReady;
    if (pending == null) return false;
    _translateWhenReady = null;
    if (!ready || state.engine == null || state.input.trim().isEmpty) {
      pending.complete();
      return false;
    }
    pending.complete(translate());
    return true;
  }

  /// "Use DuckDuckGo when Google fails" on the error of a translation that
  /// failed with Google on every volunteer server: turns the fallback on
  /// (`AppSettings.fallbackToDuckDuckGo`) and translates the input with
  /// DuckDuckGo right away, as the fallback does from now on (Google, which
  /// just failed on every server, is not asked again; the request goes
  /// through the privacy checks like any DuckDuckGo request, so it may ask
  /// for consent first). After any other error it only turns the fallback
  /// on and translates again.
  Future<void> useDuckDuckGoWhenGoogleFails() {
    _settings.setFallbackToDuckDuckGo(enabled: true);
    _debounceTimer?.cancel();
    if (state.compareMode) return runCompare();
    final error = state.error;
    if (error is AllInstancesFailedException &&
        duckDuckGoFallbackApplies(
          error,
          engine: error.engine,
          settings: _settings.state.copyWith(fallbackToDuckDuckGo: true),
          privacyMode: _privacyMode,
        )) {
      return _translate(userAsked: true, googleFailed: error);
    }
    return _translate(userAsked: true);
  }

  /// Stops what is translating the input (the go button while it runs): a
  /// pending instant translation, the main translation in flight (the text
  /// streamed so far stays, unfinished, and the status goes back to idle)
  /// and, in compare mode, the compare run (the results so far stay).
  /// Translations into the extra targets go on. Does nothing while
  /// nothing runs.
  void stopTranslation() {
    _debounceTimer?.cancel();
    if (state.comparing) {
      _cancelCompare();
      emit(state.copyWith(comparing: false));
    }
    if (state.status == TranslateStatus.translating) {
      _cancelTranslation();
      emit(state.copyWith(status: TranslateStatus.idle));
    }
    // Only an instant translation was queued.
    if (state.queued) emit(state);
  }

  /// [translate] for a translation the user did not ask for as such (a
  /// changed language, a swap): consent is only asked inline.
  Future<void> _translateAgain() {
    _debounceTimer?.cancel();
    if (state.compareMode) return runCompare();
    return _translate();
  }

  /// Translates again what [TranslateState.consent] stopped, once the user
  /// gave consent (recorded in the settings and the repository, e.g. with
  /// `requestConsent`). Without a stopped translation, translates the
  /// input.
  ///
  /// The one-request approval the answer left in the repository
  /// (`TranslationRepository.allowOnce`, also given with "Always") is for
  /// this retry only: it is withdrawn (`TranslationRepository.revokeOnce`,
  /// nothing happens when the retry used it) as soon as the retry's main
  /// translation ends or is cancelled (more typing, Stop, another
  /// translation). So when the retry does not need it, e.g. the on-device
  /// engine tried first translates now because the language was downloaded
  /// meanwhile, a later text is asked about again instead of going online
  /// on the leftover approval.
  Future<void> retryAfterConsent() async {
    final consent = state.consent?.exception;
    final retry = consent == null ? translate : _consentRetry ?? translate;
    _consentRetry = null;
    if (consent != null) emit(state.copyWith(consent: () => null));
    _withdrawRetryConsent();
    final running = retry();
    if (consent != null) {
      // The retry's main translation, when it started one.
      final main = _translationDone;
      if (main == null || main.isCompleted) {
        _repository.revokeOnce(consent);
      } else {
        _retryConsent = (consent: consent, main: main);
        unawaited(
          main.future.then((_) {
            if (identical(_retryConsent?.main, main)) _withdrawRetryConsent();
          }),
        );
      }
    }
    await running;
  }

  /// Withdraws the approval of the retry in flight ([_retryConsent]), if
  /// any (see [retryAfterConsent]).
  void _withdrawRetryConsent() {
    final grant = _retryConsent;
    _retryConsent = null;
    if (grant != null) _repository.revokeOnce(grant.consent);
  }

  /// Hides [TranslateState.consent] without translating.
  void dismissConsent() {
    _consentRetry = null;
    if (state.consent != null) emit(state.copyWith(consent: () => null));
  }

  /// In offline-first mode the Mozhi engine list is only loaded once the
  /// user lets the app use the network (`TranslationRepository
  /// .metadataDeferred`): opening the engine picker does. Loads the lists
  /// then (without the loading state); does nothing otherwise.
  Future<void> loadDeferredEngines() async {
    final bool deferred;
    try {
      deferred = _repository.metadataDeferred;
    } on Object {
      // A repository test double without privacy settings.
      return;
    }
    if (!deferred) return;
    _repository.allowMetadataRequests();
    await _loadEngines(quiet: true);
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
    bool userAsked = false,
    AllInstancesFailedException? googleFailed,
  }) {
    final main = _translateMain(
      engine: engine,
      options: options,
      text: text,
      smartSwap: smartSwap,
      auto: auto,
      external: external,
      userAsked: userAsked,
      googleFailed: googleFailed,
      // After consent: the same translation, now asked for by the user
      // (straight with DuckDuckGo when Google had failed on every server).
      retry: ({googleFailed}) => _translate(
        engine: engine,
        options: options,
        text: text,
        smartSwap: smartSwap,
        extraTargets: extraTargets,
        userAsked: true,
        googleFailed: googleFailed,
      ),
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

  /// The main translation of [_translate]. When the privacy settings stop
  /// it ([ConsentRequiredException]), [TranslateState.consent] asks for
  /// consent instead of reporting an error, and [retry] runs once it is
  /// given ([retryAfterConsent]); when they stopped the DuckDuckGo fallback,
  /// with the Google failure as `googleFailed`.
  ///
  /// With [googleFailed] (Google just failed on every server for this
  /// text), DuckDuckGo translates right away, as the fallback would
  /// ([_withDuckDuckGoFallback]); Google is not asked again.
  Future<void> _translateMain({
    required Future<void> Function({AllInstancesFailedException? googleFailed})
    retry,
    TranslationEngine? engine,
    TranslationOptions? options,
    String? text,
    bool smartSwap = true,
    bool auto = false,
    bool external = false,
    bool userAsked = false,
    AllInstancesFailedException? googleFailed,
  }) {
    final selected = engine ?? state.engine;
    final input = text ?? state.input;
    if (selected == null || input.trim().isEmpty) return Future.value();
    _cancelTranslation();
    // A translation of the input is on its way: no instant one of it.
    if (input == state.input) _debounceTimer?.cancel();
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
    _requestText = input;
    emit(
      _clearedExtras(state)
          .copyWith(status: TranslateStatus.translating, error: () => null),
    );

    // Offline first: the on-device engine lacked the language and the
    // online engine was asked instead (see onlineFallbackOf).
    var fromOnDevice = false;
    String? onDeviceSource;
    // The online engine that translated then: usage and a fallback notice
    // name it, not the on-device engine.
    TranslationEngine? routedTo;
    // Google's failure on every server when DuckDuckGo took over.
    AllInstancesFailedException? switchedAfter;

    void fail(Object error) {
      _translation = null;
      if (error is ConsentRequiredException) {
        final failed = switchedAfter;
        // The DuckDuckGo fallback waits for consent: the retry goes
        // straight there (Google just failed on every server).
        _consentRetry = failed == null
            ? retry
            : () => retry(googleFailed: failed);
        emit(
          state.copyWith(
            status: TranslateStatus.idle,
            result: () => null,
            error: () => null,
            consent: () => ConsentRequest(
              exception: error,
              id: ++_consentRequests,
              automatic: !userAsked || auto || external,
              fromOnDevice: fromOnDevice,
              onDeviceSource: onDeviceSource,
            ),
          ),
        );
      } else {
        // The parts of a long text that were finished (or the text streamed
        // so far) stay, with the error and Retry.
        final partial = state.result;
        final keep =
            partial != null &&
            !partial.isComplete &&
            partial.text.trim().isNotEmpty &&
            state.resultInput?.trimRight() == request.text.trimRight();
        emit(
          state.copyWith(
            status: TranslateStatus.failure,
            result: () => keep ? partial : null,
            error: () => error,
          ),
        );
      }
      _complete(done);
    }

    final Stream<TranslationResult> stream;
    TranslationFallback? fallback;
    void switchedToDuckDuckGo(
      TranslationEngine duckDuckGo,
      AllInstancesFailedException failure,
    ) {
      routedTo = duckDuckGo;
      switchedAfter = failure;
      fallback = TranslationFallback(
        fromEngineName: failure.engine.name,
        engineName: duckDuckGo.name,
        onDevice: false,
        allServersFailed: true,
      );
    }

    try {
      final Stream<TranslationResult> results;
      if (googleFailed != null) {
        results = _duckDuckGoAfter(
          googleFailed,
          request,
          onSwitch: switchedToDuckDuckGo,
        );
      } else {
        results = _withDuckDuckGoFallback(
          request,
          _onDeviceThenOnline(
            selected,
            request,
            onRouted: (source, online) {
              fromOnDevice = true;
              onDeviceSource = source;
              routedTo = online;
            },
          ),
          translatedBy: () => routedTo ?? selected,
          onSwitch: switchedToDuckDuckGo,
        );
      }
      stream = _withFallback(
        selected,
        request,
        results,
        onFallback: (value) => fallback = value,
        translatedBy: () => routedTo ?? selected,
      );
    } on Object catch (error) {
      fail(error);
      return done.future;
    }
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
        _onResult(
          selected,
          request,
          result,
          smartSwap: smartSwap,
          auto: auto,
          external: external,
          fallback: result.isComplete ? fallback : null,
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

  /// [fallback] is set for the final result of a fallback engine.
  void _onResult(
    TranslationEngine engine,
    TranslationRequest request,
    TranslationResult result, {
    required bool smartSwap,
    required bool auto,
    required bool external,
    TranslationFallback? fallback,
  }) {
    // White space typed at the end meanwhile does not make it stale.
    final made = request.text.trimRight() == state.input.trimRight()
        ? state.input
        : request.text;
    if (!result.isComplete) {
      emit(
        state.copyWith(
          result: () => result,
          resultInput: () => made,
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
    _resultLanguages = (source: request.source, target: request.target);
    emit(
      state.copyWith(
        result: () => result,
        resultInput: () => made,
        instantResult: auto || external,
        status: TranslateStatus.success,
        fallback: () => fallback,
      ),
    );
    // An extra target in the detected language of the input is dropped
    // (cancelled when in flight).
    _pruneExtraTranslations();
    // A fallback's result, or the online engine's after the on-device one
    // lacked the language (onlineFallbackOf), names the engine that
    // translated.
    final own =
        fallback == null && !(engine.isOffline && result.engineId != engine.id);
    _record(
      request,
      result,
      engineId: own ? engine.id : result.engineId,
      engineName: own ? engine.name : result.engineName,
      auto: auto,
    );
    _settings.recordPair(
      _languageOf(request.source, result.detectedSource),
      request.target,
    );
    _autoRomanize();
    unawaited(loadUncertainty());
  }

  /// In Offline first, the online engine the app asks about when the
  /// on-device engine it picked by itself can't translate the text (its
  /// language is not downloaded, or the engine has no model for it): the
  /// default Mozhi engine (Google) on the first instance of the user's list
  /// (as listed in [state], or as it will be once the lists are loaded).
  ///
  /// Null unless all of these hold: the privacy mode is
  /// [PrivacyMode.offlineFirst], the selected engine is the on-device one,
  /// the user has not chosen an engine (`AppSettings.engineId` is null:
  /// picking the on-device engine keeps the text on the device), no quality
  /// mode is on and there is an instance.
  ///
  /// The online engine gets the text only through the repository's consent
  /// check (`TranslationRepository.translate`): for a language pair the user
  /// has not allowed, it stops before anything is sent and the screen asks
  /// (Once, Always for the pair) next to the download of the language.
  static TranslationEngine? onlineFallbackOf(
    TranslateState state,
    AppSettings settings,
  ) {
    final engine = state.engine;
    if (engine == null ||
        !engine.isOffline ||
        settings.privacyMode != PrivacyMode.offlineFirst ||
        settings.engineId != null ||
        state.qualityMode != QualityMode.off ||
        settings.instances.isEmpty) {
      return null;
    }
    return _engineIn(state.engines, _defaultEngineId) ??
        TranslationEngine(
          id: _defaultEngineId,
          kind: EngineKind.mozhi,
          name: 'Google',
          subtitle: settings.instances.first.displayName,
          mozhiEngine: 'google',
        );
  }

  /// Whether the on-device engine failed with [error] because it can't
  /// translate the text on this device: a language whose models are not
  /// downloaded, or one it has no model for (also when the platform wraps
  /// the exception).
  static bool _lacksOnDevice(Object error) => switch (error) {
    OfflineModelMissingException() ||
    OfflineLanguageUnsupportedException() => true,
    _ =>
      '$error'.contains('OfflineModelMissingException') ||
          '$error'.contains('OfflineLanguageUnsupportedException'),
  };

  /// The source language the on-device engine recognised before [error]
  /// (the missing language of [request] that is not its target), or null.
  static String? _recognisedSource(Object error, TranslationRequest request) {
    if (!request.source.isAuto) return request.source.code;
    if (error is! OfflineModelMissingException) return null;
    final target = LanguageMatcher.normalize(request.target.code)
        .split('-')
        .first
        .toLowerCase();
    for (final code in error.languages) {
      final key = LanguageMatcher.normalize(code).split('-').first;
      if (key.toLowerCase() != target) return code;
    }
    return null;
  }

  /// [selected]'s translation of [request]; in Offline first with the
  /// on-device engine the app picked ([onlineFallbackOf]), when the device
  /// can't translate it ([_lacksOnDevice]), the online engine's translation
  /// instead, through the repository's consent check (a
  /// [ConsentRequiredException] before anything is sent unless the pair is
  /// allowed). [onRouted] gets the source language the device recognised
  /// and the online engine asked when that happens.
  Stream<TranslationResult> _onDeviceThenOnline(
    TranslationEngine selected,
    TranslationRequest request, {
    required void Function(String? onDeviceSource, TranslationEngine online)
    onRouted,
  }) {
    final local = _repository.translate(selected, request);
    final online = selected.id == state.engine?.id
        ? onlineFallbackOf(state, _settings.state)
        : null;
    if (online == null) return local;
    late final StreamController<TranslationResult> controller;
    StreamSubscription<TranslationResult>? subscription;
    var cancelled = false;
    void fail(Object error, [StackTrace? stackTrace]) {
      if (controller.isClosed) return;
      controller.addError(error, stackTrace);
      unawaited(controller.close());
    }

    Future<void> goOnline(Object error, StackTrace stackTrace) async {
      // The on-device engine's codes are not all the online engine's
      // (`zh-Hant`, `he` are Google's `zh-TW`, `iw`): without the languages
      // in its lists, the download stays the way to translate this. Lists
      // it can't give now: the common codes (the request still asks for
      // consent first, and its failure is reported then).
      final mapped = await _requestOnto(
        online,
        request,
        catalogueWhenUnavailable: true,
      );
      if (cancelled || controller.isClosed) return;
      if (mapped == null) return fail(error, stackTrace);
      onRouted(_recognisedSource(error, request), online);
      final Stream<TranslationResult> remote;
      try {
        remote = _repository.translate(online, mapped);
      } on Object catch (error, stackTrace) {
        return fail(error, stackTrace);
      }
      subscription = remote.listen(
        controller.add,
        onError: fail,
        onDone: () => unawaited(controller.close()),
        cancelOnError: true,
      );
    }

    controller = StreamController<TranslationResult>(
      onListen: () {
        subscription = local.listen(
          controller.add,
          onError: (Object error, StackTrace stackTrace) {
            // The settings may have changed meanwhile (an engine picked,
            // another privacy mode): then it is a plain failure.
            if (!_lacksOnDevice(error) ||
                onlineFallbackOf(state, _settings.state)?.id != online.id) {
              return fail(error, stackTrace);
            }
            unawaited(goOnline(error, stackTrace));
          },
          onDone: () => unawaited(controller.close()),
          cancelOnError: true,
        );
      },
      onPause: () => subscription?.pause(),
      onResume: () => subscription?.resume(),
      onCancel: () {
        cancelled = true;
        return subscription?.cancel();
      },
    );
    return controller.stream;
  }

  /// Whether the DuckDuckGo fallback (`AppSettings.fallbackToDuckDuckGo`)
  /// takes over after [error] of a text translation by [engine], with
  /// [settings] and the repository's [privacyMode]: all of these hold.
  ///
  /// * The fallback is on (the default, unless the user turned it off).
  /// * [engine] is Mozhi's Google engine (not DuckDuckGo already, nor any
  ///   other engine), and [error] is an [AllInstancesFailedException] for
  ///   it: every volunteer server the request was allowed to go to failed.
  /// * At least one server answered (`AllInstancesFailedException
  ///   .serverAnswered`: Google failed behind it). When none could be
  ///   reached, DuckDuckGo would not get through the same servers either.
  /// * The failure was not the network policy refusing the request
  ///   ([NetworkPolicyError]: plain `http` to a public server, a missing
  ///   proxy); a consent refusal is a [ConsentRequiredException], never
  ///   this.
  /// * Neither the settings nor the repository are in
  ///   [PrivacyMode.offlineOnly].
  ///
  /// The DuckDuckGo request still goes through the repository's privacy
  /// checks like any other.
  static bool duckDuckGoFallbackApplies(
    Object error, {
    required TranslationEngine engine,
    required AppSettings settings,
    PrivacyMode? privacyMode,
  }) {
    if (!settings.fallbackToDuckDuckGo ||
        settings.privacyMode == PrivacyMode.offlineOnly ||
        privacyMode == PrivacyMode.offlineOnly ||
        !_isGoogle(engine) ||
        error is! AllInstancesFailedException ||
        !_isGoogle(error.engine) ||
        !error.serverAnswered) {
      return false;
    }
    return NetworkPolicyError.of(error.cause ?? error) == null;
  }

  /// Whether [engine] is Mozhi's Google engine.
  static bool _isGoogle(TranslationEngine engine) =>
      engine.isMozhi &&
      (engine.mozhiEngine ?? engine.id.substring(engine.id.indexOf(':') + 1))
              .toLowerCase() ==
          'google';

  /// The repository's privacy mode (null for a test double without one).
  PrivacyMode? get _privacyMode {
    try {
      return _repository.privacyMode;
    } on Object {
      return null;
    }
  }

  /// Mozhi's DuckDuckGo engine, as the active instance lists it (or as it
  /// would, when the lists are not loaded or it is not listed).
  TranslationEngine _duckDuckGoEngine() =>
      _engineIn(state.engines, duckDuckGoEngineId) ??
      TranslationEngine.mozhi('duckduckgo', 'DuckDuckGo');

  /// [results], a text translation of [request] by [translatedBy] (asked
  /// when it fails), with the DuckDuckGo fallback: when they fail and
  /// [duckDuckGoFallbackApplies], the events of DuckDuckGo's translation of
  /// [request] follow ([_duckDuckGoAfter], once: [onSwitch] gets the
  /// DuckDuckGo engine and Google's failure when it is asked). Other errors
  /// are forwarded as they are.
  Stream<TranslationResult> _withDuckDuckGoFallback(
    TranslationRequest request,
    Stream<TranslationResult> results, {
    required TranslationEngine Function() translatedBy,
    void Function(
      TranslationEngine duckDuckGo,
      AllInstancesFailedException failure,
    )?
    onSwitch,
  }) {
    late final StreamController<TranslationResult> controller;
    StreamSubscription<TranslationResult>? subscription;
    void fail(Object error, [StackTrace? stackTrace]) {
      if (controller.isClosed) return;
      controller.addError(error, stackTrace);
      unawaited(controller.close());
    }

    controller = StreamController<TranslationResult>(
      onListen: () {
        subscription = results.listen(
          controller.add,
          onError: (Object error, StackTrace stackTrace) {
            // Read now: the user may have changed the setting meanwhile.
            if (error is! AllInstancesFailedException ||
                !duckDuckGoFallbackApplies(
                  error,
                  engine: translatedBy(),
                  settings: _settings.state,
                  privacyMode: _privacyMode,
                )) {
              return fail(error, stackTrace);
            }
            subscription = _duckDuckGoAfter(error, request, onSwitch: onSwitch)
                .listen(
                  controller.add,
                  onError: fail,
                  onDone: () => unawaited(controller.close()),
                  cancelOnError: true,
                );
          },
          onDone: () => unawaited(controller.close()),
          cancelOnError: true,
        );
      },
      onPause: () => subscription?.pause(),
      onResume: () => subscription?.resume(),
      onCancel: () => subscription?.cancel(),
    );
    return controller.stream;
  }

  /// DuckDuckGo's translation of [request] after Google's [failure] on
  /// every server (the DuckDuckGo fallback). Google's language codes are
  /// not all DuckDuckGo's (`zh-CN`, `iw`, `tl`, `no`, `sr` are its `zh`,
  /// `he`, `fil`, `nb`, `sr-Cyrl`), so the languages are mapped onto
  /// DuckDuckGo's lists first ([_requestOnto]); [onSwitch] gets the
  /// DuckDuckGo engine and [failure] when it is asked.
  ///
  /// Fails with [failure] itself, so that the user sees why Google failed
  /// (and what can be done about it), when DuckDuckGo does not offer one of
  /// the languages, its lists cannot be loaded, or Mozhi rejects the
  /// request as invalid ([TranslationRepository.isMozhiInputError], e.g.
  /// an instance without DuckDuckGo: "Engine does not exist"). Its other
  /// errors, a consent refusal included, are forwarded.
  Stream<TranslationResult> _duckDuckGoAfter(
    AllInstancesFailedException failure,
    TranslationRequest request, {
    void Function(
      TranslationEngine duckDuckGo,
      AllInstancesFailedException failure,
    )?
    onSwitch,
  }) {
    final duckDuckGo = _duckDuckGoEngine();
    late final StreamController<TranslationResult> controller;
    StreamSubscription<TranslationResult>? subscription;
    var cancelled = false;
    void fail(Object error, [StackTrace? stackTrace]) {
      if (controller.isClosed) return;
      if (TranslationRepository.isMozhiInputError(error)) {
        controller.addError(failure);
      } else {
        controller.addError(error, stackTrace);
      }
      unawaited(controller.close());
    }

    Future<void> start() async {
      final mapped = await _requestOnto(duckDuckGo, request);
      if (cancelled || controller.isClosed) return;
      if (mapped == null) return fail(failure);
      final Stream<TranslationResult> results;
      try {
        results = _repository.translate(duckDuckGo, mapped);
      } on Object catch (error, stackTrace) {
        return fail(error, stackTrace);
      }
      onSwitch?.call(duckDuckGo, failure);
      subscription = results.listen(
        controller.add,
        onError: fail,
        onDone: () => unawaited(controller.close()),
        cancelOnError: true,
      );
    }

    controller = StreamController<TranslationResult>(
      onListen: () => unawaited(start()),
      onPause: () => subscription?.pause(),
      onResume: () => subscription?.resume(),
      onCancel: () {
        cancelled = true;
        return subscription?.cancel();
      },
    );
    return controller.stream;
  }

  /// [request] with its languages as [engine] lists them
  /// ([TranslationRepository.getSourceLanguages] and
  /// [TranslationRepository.getTargetLanguages], which keep the lists;
  /// [LanguageMatcher.match]), for an engine the languages were not picked
  /// for: another engine may know them by other codes (Google's `zh-CN` is
  /// DuckDuckGo's `zh`, the on-device engine's `zh-Hant` is Google's
  /// `zh-TW`), and Mozhi rejects a code its engine does not list.
  ///
  /// Null when [engine] does not offer one of the languages (detection
  /// included; custom languages only for an engine that takes them) or,
  /// without [catalogueWhenUnavailable], its lists cannot be loaded. With
  /// [catalogueWhenUnavailable], lists that cannot be loaded (not yet: a
  /// [ConsentRequiredException] in offline first before a request was let
  /// leave the device, nothing stored; or no server answered) are replaced
  /// by the [LanguageCatalog], whose codes are the common ones.
  Future<TranslationRequest?> _requestOnto(
    TranslationEngine engine,
    TranslationRequest request, {
    bool catalogueWhenUnavailable = false,
  }) async {
    List<Language> sources;
    List<Language> targets;
    try {
      sources = await _repository.getSourceLanguages(engine);
      targets = await _repository.getTargetLanguages(engine);
    } on Object {
      if (!catalogueWhenUnavailable) return null;
      sources = [Language.auto, ...LanguageCatalog.all];
      targets = LanguageCatalog.all;
    }
    Language? onto(Language language, List<Language> languages) {
      if (language.isAuto) {
        return languages.contains(Language.auto) ? Language.auto : null;
      }
      if (language.isCustom) {
        return engine.supportsCustomLanguages ? language : null;
      }
      return LanguageMatcher.match(language, languages);
    }

    final source = onto(request.source, sources);
    final target = onto(request.target, targets);
    if (source == null || target == null || target.isAuto) return null;
    return request.copyWith(source: source, target: target);
  }

  /// [results], [selected]'s translation of [request], with the fallback of
  /// the class documentation: a final result that is suspect is forwarded
  /// unfinished while the engines of [_fallbackEngines] are tried in turn
  /// (their errors and suspect results move on to the next); the first
  /// good result is forwarded (after [onFallback] got its notice), else the
  /// suspect one. Usage is recorded for every final result that did not
  /// come from the cache (once per engine). Cancelling cancels the request
  /// in flight.
  ///
  /// [translatedBy] is the engine that made [results] (default [selected]):
  /// the online engine when the on-device engine lacked the language
  /// ([_onDeviceThenOnline]); usage and the notice's "from" engine are its.
  /// The engines tried next are still chosen for [selected], so text the
  /// app meant to keep on the device only goes on to on-device engines.
  Stream<TranslationResult> _withFallback(
    TranslationEngine selected,
    TranslationRequest request,
    Stream<TranslationResult> results, {
    required void Function(TranslationFallback fallback) onFallback,
    TranslationEngine Function()? translatedBy,
  }) {
    late final StreamController<TranslationResult> controller;
    StreamSubscription<TranslationResult>? subscription;
    TranslationResult? suspect;
    var suspectEngine = selected;
    var candidates = const <TranslationEngine>[];
    var counted = false;

    void count(TranslationEngine engine, TranslationResult result) {
      if (!result.fromCache) {
        _recordUsage(engine, input: request.text, output: result.text);
      }
    }

    void close([TranslationResult? last]) {
      if (controller.isClosed) return;
      if (last != null) controller.add(last);
      unawaited(controller.close());
    }

    late final void Function() tryNext;
    tryNext = () {
      if (controller.isClosed) return;
      if (candidates.isEmpty) return close(suspect);
      final engine = candidates.first;
      candidates = candidates.sublist(1);
      final Stream<TranslationResult> stream;
      try {
        stream = _repository.translate(engine, request);
      } on Object {
        return tryNext();
      }
      var done = false;
      subscription = stream.listen(
        (result) {
          if (done || !result.isComplete) return;
          done = true;
          count(engine, result);
          if (result.isSuspect) return;
          final first = suspect!;
          onFallback(
            TranslationFallback(
              fromEngineName: suspectEngine.name,
              reason: first.warnings
                  .firstWhere((warning) => warning.isSuspect)
                  .kind,
              engineName: engine.name,
              onDevice: engine.isOffline,
            ),
          );
          close(result);
        },
        onError: (Object _) => tryNext(),
        onDone: () {
          if (!controller.isClosed) tryNext();
        },
        cancelOnError: true,
      );
    };

    controller = StreamController<TranslationResult>(
      onListen: () {
        subscription = results.listen(
          (result) {
            if (result.isComplete && !counted) {
              // The provider did the work even when a smart swap or a
              // fallback follows (but not for results served from the
              // cache).
              counted = true;
              count(translatedBy?.call() ?? selected, result);
            }
            if (result.isComplete && result.isSuspect && suspect == null) {
              final next = _fallbackEngines(selected, request);
              if (next.isNotEmpty) {
                suspect = result;
                suspectEngine = translatedBy?.call() ?? selected;
                candidates = next;
                controller.add(result.copyWith(isComplete: false));
                return;
              }
            }
            controller.add(result);
          },
          onError: controller.addError,
          onDone: () {
            if (suspect != null) return tryNext();
            close();
          },
        );
      },
      onPause: () => subscription?.pause(),
      onResume: () => subscription?.resume(),
      onCancel: () => subscription?.cancel(),
    );
    return controller.stream;
  }

  /// The engines tried after a suspect result of [from] for [request] (see
  /// the class documentation), at most [maxFallbackEngines]. When [from]
  /// keeps the text on the device ([_staysOnDevice]), so do they: the text
  /// never leaves the device unasked.
  List<TranslationEngine> _fallbackEngines(
    TranslationEngine from,
    TranslationRequest request,
  ) {
    final onDeviceOnly = _staysOnDevice(from);
    bool allowed(TranslationEngine engine) {
      try {
        return !_repository.needsConsent(
          engine,
          source: request.source,
          target: request.target,
        );
      } on Object {
        // A repository test double without privacy settings.
        return false;
      }
    }

    return [
      for (final engine in state.engines)
        if (engine.isOffline && engine.id != from.id) engine,
      // Network engines (public servers, the user's own servers): never
      // for text that stayed on the device.
      if (!onDeviceOnly)
        for (final engine in state.engines)
          if (!engine.isOffline &&
              // On-device AI would load a 1-3 GB model unasked: only when
              // chosen.
              !(engine.isAi && engine.onDevice) &&
              engine.id != from.id &&
              !_isCloudEngine(engine) &&
              allowed(engine))
            engine,
    ].take(maxFallbackEngines).toList();
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
    // A retry after consent that is cancelled leaves no approval behind.
    _withdrawRetryConsent();
    _translationRequest++;
    unawaited(_translation?.cancel());
    _translation = null;
    final done = _translationDone;
    _translationDone = null;
    if (done != null) _complete(done);
  }

  /// Adds the translation to history when enabled (`saveHistory`, and
  /// never in incognito mode). The history repository
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
    final settings = _settings.state;
    if (!settings.saveHistory ||
        settings.incognito ||
        result.text.trim().isEmpty) {
      return;
    }
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
    _typingEntryIds.add(id);
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

  /// Turns compare mode on or off. A pending instant translation is
  /// dropped so that it cannot start a compare run nobody asked for.
  ///
  /// Turning it on compares at once when there is input ([runCompare]):
  /// choosing Compare asks for it, and every engine still goes through the
  /// privacy settings (an engine that needs consent reports it on its card
  /// and gets nothing). Turning it off keeps the translation.
  void setCompareMode({required bool enabled}) {
    if (enabled == state.compareMode) return;
    _debounceTimer?.cancel();
    _cancelCompare();
    emit(
      state.copyWith(
        compareMode: enabled,
        compareEntries: const [],
        comparing: false,
        compareBaseline: () => null,
      ),
    );
    if (enabled && state.input.trim().isNotEmpty) unawaited(runCompare());
  }

  /// Runs the compare engines ([TranslateState.compareEnginesFor] the
  /// configured `AppSettings.compareEngineIds`: all when none is
  /// configured; AI only for custom languages) and collects their results
  /// as they arrive, ordered like the engines (not by arrival).
  ///
  /// The finished, current translation of the input (into the same
  /// languages, from an engine rather than the history) is the first
  /// result ([TranslateState.compareBaseline]): its engine is not asked
  /// again.
  Future<void> runCompare() {
    _debounceTimer?.cancel();
    final text = state.input;
    final engines = state.compareEnginesFor(_settings.state.compareEngineIds);
    if (text.trim().isEmpty || engines.isEmpty) {
      if (state.queued) emit(state);
      return Future.value();
    }
    final baseline = _currentResultForCompare();
    final asked = [
      for (final engine in engines)
        if (engine.id != baseline?.engineId) engine,
    ];

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
    // Cards follow the engines: the current translation first.
    final order = [
      ?baseline?.engineId,
      for (final engine in engines) engine.id,
    ];
    int rank(CompareEntry entry) {
      final index = order.indexOf(entry.id);
      return index < 0 ? order.length : index;
    }

    emit(
      state.copyWith(
        compareEntries: [if (baseline != null) CompareEntry.success(baseline)],
        compareBaseline: () => baseline,
        comparing: asked.isNotEmpty,
        error: () => null,
      ),
    );
    if (asked.isEmpty) {
      _complete(done);
      return done.future;
    }

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
      stream = _repository.compare(asked, request);
    } on Object catch (error) {
      finish(error: error);
      return done.future;
    }
    _compare = stream.listen(
      (entry) {
        if (!_isCurrentCompare(id)) return;
        final result = entry.result;
        if (result != null && result.isComplete && !result.fromCache) {
          for (final engine in asked) {
            if (engine.id == entry.id) {
              _recordUsage(engine, input: text, output: result.text);
              break;
            }
          }
        }
        final entries = [...state.compareEntries, entry];
        // A stable sort: two results of one engine keep their order.
        final ranked =
            [for (final (index, entry) in entries.indexed) (index, entry)]
              ..sort((a, b) {
                final byRank = rank(a.$2).compareTo(rank(b.$2));
                return byRank != 0 ? byRank : a.$1.compareTo(b.$1);
              });
        emit(
          state.copyWith(
            compareEntries: List.unmodifiable([
              for (final (_, entry) in ranked) entry,
            ]),
          ),
        );
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

  /// The result a compare run starts from (see [runCompare]): the shown
  /// translation when it is finished, not empty, of the current input and
  /// languages, and from an engine (not the history); else null.
  TranslationResult? _currentResultForCompare() {
    final result = state.result;
    final languages = _resultLanguages;
    if (result == null ||
        !result.isComplete ||
        result.text.trim().isEmpty ||
        state.isResultStale ||
        state.resultFromMemory ||
        state.status == TranslateStatus.translating ||
        languages == null ||
        languages.source != state.source ||
        languages.target != state.target) {
      return null;
    }
    return result;
  }

  /// Selects [entry] as the main result (and its engine: choosing another
  /// engine turns quality mode off, like [selectEngine], or, once Fast and
  /// Best are set up, makes it the active mode's engine). The current
  /// translation's own entry ([TranslateState.compareBaseline]) just
  /// leaves compare mode.
  void useCompareEntry(CompareEntry entry) {
    final result = entry.result;
    if (result == null) return;
    if (result == state.compareBaseline) {
      setCompareMode(enabled: false);
      return;
    }
    TranslationEngine? engine;
    for (final candidate in state.engines) {
      if (candidate.id == entry.id) engine = candidate;
    }
    if (engine == null) return;
    _debounceTimer?.cancel();
    _cancelCompare();
    _cancelTranslation();
    _resultLanguages = (source: state.source, target: state.target);
    emit(
      _clearedExtras(state).copyWith(
        compareMode: false,
        compareEntries: const [],
        comparing: false,
        compareBaseline: () => null,
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
      if (_assignToMode(engine)) {
        unawaited(_switchEngine(engine, keepResult: true, persist: false));
      } else {
        _leaveQualityMode();
        unawaited(_switchEngine(engine, keepResult: true));
      }
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
  /// the given order). They replace every pick, also the ones the engine
  /// does not offer ([TranslateState.unavailableExtraTargets]): `[]`
  /// removes them all. They are saved (`SettingsCubit.setExtraTargets`).
  ///
  /// Picks the engine does not offer stay picked: they are not translated
  /// (and get no card) until an engine that offers them is selected, and
  /// they count towards [maxExtraTargets].
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
    final next = AppSettings.normalizeExtraTargets(targets);
    if (_sameLanguages(next, state.extraTargets)) return;
    _settings.setExtraTargets(next);
    _applyExtraTargets(next);
  }

  /// Applies extra targets saved by someone else (`AppSettings.extraTargets`
  /// changed and differs from [TranslateState.extraTargets]).
  void _syncExtraTargets() {
    final saved = _settings.state.extraTargets;
    if (isClosed || _sameLanguages(saved, _seenExtraTargets)) return;
    _seenExtraTargets = saved;
    _applyExtraTargets(AppSettings.normalizeExtraTargets(saved));
  }

  /// Shows [next] as [TranslateState.extraTargets] and translates the
  /// input into the new ones when it has a current translation (see
  /// [setExtraTargets]).
  void _applyExtraTargets(List<Language> next) {
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
  /// [language], or one of [TranslateState.unavailableExtraTargets]); see
  /// [setExtraTargets]. Nothing is added when [maxExtraTargets] are picked
  /// already (also counting the ones the engine does not offer).
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
      stream = _withDuckDuckGoFallback(
        request,
        _repository.translate(engine, request),
        translatedBy: () => engine,
      );
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
  /// (`TranslationEngine.isLocal`; on-device AI not after an instant
  /// translation while the device is strained; for a translation made on
  /// this device only an engine on this device). The romanization is reset
  /// whenever the result changes.
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
  /// transliterations and it costs nothing (see [loadRomanization]). A
  /// translation made on this device is only romanized on its own by an
  /// engine on this device too, never by a server on the network.
  void _autoRomanize() {
    final result = state.result;
    if (result == null || !_settings.state.showTransliteration) return;
    final assist = state.assistEngine;
    final free =
        result.targetTransliteration.trim().isNotEmpty ||
        (assist != null &&
            assist.isLocal &&
            (_staysOnDevice(assist) || !_translatedOnDevice(result)) &&
            // Typing doesn't start on-device AI while the device is
            // strained, nor its extras.
            !(state.instantResult && _sparesDevice(assist)));
    if (free && state.canRomanize) unawaited(loadRomanization());
  }

  /// Whether the engine of [result] (else the selected one) keeps the text
  /// on this device ([_staysOnDevice]).
  bool _translatedOnDevice(TranslationResult result) {
    final engine =
        state.engines.where((e) => e.id == result.engineId).firstOrNull ??
        state.engine;
    return engine != null && _staysOnDevice(engine);
  }

  /// Finds the corresponding phrases of the input and the output
  /// ([TranslateState.alignment], on demand) with
  /// [TranslateState.alignmentEngine] (`TranslationRepository.align`): the
  /// on-device engine for its own translations (free, nothing is recorded
  /// in the usage), else the AI [TranslateState.assistEngine] (only the
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
    final engine = state.alignmentEngine!;
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
      if (!engine.isOffline) {
        _recordUsage(
          engine,
          input: '$source\n$translation',
          output: _alignmentText(spans, source, translation),
        );
      }
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
      consent: () => null,
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

  // ---------------------------------------------------------------------
  // Translation memory
  // ---------------------------------------------------------------------

  /// Looks the input up in the history ([TranslateState.memoryMatch])
  /// whenever the input or the languages change, in the same emission.
  ///
  /// [TranslateState.queued] always says whether an instant translation is
  /// scheduled at the time of the emission.
  @override
  void emit(TranslateState state) {
    final previous = this.state;
    var next = state;
    final queued = _debounceTimer?.isActive ?? false;
    if (next.queued != queued) next = next.copyWith(queued: queued);
    if (next.input.trim().isEmpty) _typingEntryIds.clear();
    if (next.input != previous.input ||
        next.source != previous.source ||
        next.target != previous.target) {
      _memoryDismissed = false;
      final match = _lookUpMemory(next);
      if (match != next.memoryMatch) {
        next = next.copyWith(memoryMatch: () => match);
      }
    }
    super.emit(next);
  }

  /// Looks the input up again when the history changes: a translation is
  /// saved (encrypted) after a moment, so text typed again right away (or
  /// before the history was read) would otherwise miss it; a deleted entry
  /// is no longer offered. The translation just made of this very input
  /// ([_typingEntryIds]) is not offered back, and a dismissed match stays
  /// hidden.
  void _onHistory(HistoryState history) {
    if (isClosed || _memoryDismissed || state.input.trim().isEmpty) return;
    var match = _lookUpMemory(state);
    if (match != null && _typingEntryIds.contains(match.entry.id)) {
      match = state.memoryMatch;
    }
    if (match != state.memoryMatch) {
      emit(state.copyWith(memoryMatch: () => match));
    }
  }

  /// The best earlier translation of [state]'s input into its target in
  /// the history, or null (also when history is off or not readable).
  MemoryMatch? _lookUpMemory(TranslateState state) {
    final settings = _settings.state;
    if (!settings.saveHistory || state.input.trim().isEmpty) return null;
    return _memory.lookup(
      state.input,
      source: state.source,
      target: state.target,
      entries: _history.state.entries,
      maxAge: settings.historyRetention.maxAge,
      now: _clock(),
      excludeFuzzy: _typingEntryIds,
    );
  }

  /// Shows the translation of [TranslateState.memoryMatch] as the output
  /// (marked [TranslateState.resultFromMemory]): a pending or running
  /// translation of the input is cancelled, nothing is sent to an engine,
  /// counted as usage or recorded in history again. Extras are reset. A
  /// similar (not exact) match is shown as the translation of its own
  /// text, so the output reads as not quite current
  /// ([TranslateState.isResultStale]). Translate again for a fresh one.
  void useMemoryMatch() {
    final match = state.memoryMatch;
    if (match == null || state.compareMode) return;
    final entry = match.entry;
    _debounceTimer?.cancel();
    _cancelTranslation();
    _externalPending = false;
    emit(
      _clearedExtras(state).copyWith(
        result: () => TranslationResult(
          engineId: entry.engineId,
          engineName: entry.engineName,
          text: entry.translation,
          detectedSource: entry.detectedSource,
          fromCache: true,
        ),
        resultInput: () => match.isExact ? state.input : entry.text,
        resultFromMemory: true,
        // Not asked of an engine: paid extras are not started on their own.
        instantResult: true,
        status: TranslateStatus.success,
        error: () => null,
      ),
    );
    _autoRomanize();
  }

  /// Hides [TranslateState.memoryMatch] until the input or the languages
  /// change.
  void dismissMemoryMatch() {
    if (state.memoryMatch == null) return;
    _memoryDismissed = true;
    emit(state.copyWith(memoryMatch: () => null));
  }

  @override
  Future<void> close() {
    _debounceTimer?.cancel();
    _translateWhenReady?.complete();
    _translateWhenReady = null;
    _enginesRequest++;
    _languagesRequest++;
    _cancelTranslation();
    _cancelCompare();
    _cancelExplanation();
    _cancelRefinement();
    _withoutExtraTranslations(state);
    unawaited(_settingsSubscription.cancel());
    unawaited(_historySubscription.cancel());
    unawaited(_metadataSubscription?.cancel());
    return super.close();
  }

  // ---------------------------------------------------------------------
  // Result area (Wave 2)
  // ---------------------------------------------------------------------

  /// Low-confidence look-ups started ([loadUncertainty]); a newer one wins.
  int _uncertaintyRequests = 0;

  /// Finds the sentences of the shown translation the on-device engine is
  /// unsure about ([TranslateState.lowConfidenceSentences]), with
  /// `TranslationRepository.lowConfidenceSentences`: the input is
  /// translated again on the device with details (instant, from the
  /// engine's sentence cache). Called when an on-device translation
  /// finished.
  ///
  /// Only for a finished, current result of the on-device engine (also one
  /// it produced as a fallback); never for other engines, so it never
  /// sends anything, and nothing is counted as usage. Does nothing when the
  /// sentences of this result are known already. Errors are ignored (the
  /// hint is optional); nothing is emitted when no sentence is unsure.
  Future<void> loadUncertainty() async {
    final result = state.result;
    if (result == null ||
        !result.isComplete ||
        state.isResultStale ||
        state.status != TranslateStatus.success ||
        state.uncertainResult == result) {
      return;
    }
    TranslationEngine? engine;
    for (final candidate in state.engines) {
      if (candidate.isOffline && candidate.id == result.engineId) {
        engine = candidate;
      }
    }
    if (engine == null) return;
    final source = state.resultInput ?? state.input;
    final token = ++_uncertaintyRequests;
    try {
      final spans = await _repository.lowConfidenceSentences(
        engine,
        source: source,
        translation: result.text,
        sourceLanguage: _effectiveSource(),
        targetLanguage: state.target,
      );
      if (isClosed ||
          token != _uncertaintyRequests ||
          state.result != result ||
          spans.isEmpty) {
        return;
      }
      emit(
        state.copyWith(
          uncertainSentences: List<AlignedSpan>.unmodifiable(spans),
          uncertainResult: () => result,
        ),
      );
    } on Object {
      // No hint then.
    }
  }

  /// Uses [text] as the whole translation (another translation the engine
  /// returned for a short input, `TranslationResult.targetSynonyms`), like
  /// [useAlternative] for the whole output, also after alternatives for a
  /// part of it were used.
  void useOtherTranslation(String text) {
    if (state.alternativesSpan != null) {
      emit(
        state.copyWith(
          alternativesSpan: () => null,
          alternativesSpanStart: () => null,
        ),
      );
    }
    useAlternative(text);
  }
}
