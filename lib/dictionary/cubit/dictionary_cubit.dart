import 'dart:async';

import 'package:bloc/bloc.dart';
import 'package:mozhi/dictionary/cubit/dictionary_state.dart';
import 'package:mozhi/history/cubit/history_cubit.dart';
import 'package:mozhi/history/models/history_entry.dart';
import 'package:mozhi/settings/cubit/settings_cubit.dart';
import 'package:mozhi/usage/data/usage_tracker.dart';
import 'package:translation_repository/translation_repository.dart';

export 'dictionary_state.dart';

/// Drives the dictionary page: looks words up in the installed offline
/// dictionaries (`offlineDictionary`, see below), else with an AI engine
/// ([TranslationRepository.lookUp]).
///
/// * With offline dictionaries installed ([DictionaryState.offlineLanguages],
///   kept up to date through [OfflineDictionary.changes]), [lookUp] asks
///   them first: their answer is the entry
///   ([DictionaryState.offlineAnswer]: no network, nothing sent anywhere).
///   Without an answer it asks the AI engine; without one either, it ends
///   with no entry and the [DictionaryState.suggestions] of the
///   dictionaries. [moreDetail] then asks the AI engine for the shown word
///   (and [retry] repeats the last kind of request). Changing the detail
///   level or the engine only looks an AI entry up again.
/// * Only engines that [TranslationEngine.supportsExtras] are used.
/// * [lookUp] before an engine is available waits for one: the look-up
///   runs as soon as [setEngine] provides it (unless the word changed).
/// * Changing a language looks the word up again once something was looked
///   up (the user asked for a word already).
/// * Changing the detail level ([setVerbosity]) looks the shown (or
///   loading) word up again with it; it never starts a look-up on its own.
/// * [lookUpWord] follows a related word or the suggested spelling of an
///   entry. Nothing else starts a request on its own.
/// * Finished requests to a bring-your-own-key provider are counted by the
///   optional `usageTracker`; tracker errors are ignored.
/// * History (optional `history` and `settings`): every look-up that finds
///   an entry is saved as a dictionary entry of the history
///   ([HistoryEntryKind.dictionary]: the word, its languages, the engine,
///   the detail level and a one-line [historySummary]) when
///   `AppSettings.saveHistory` is on and incognito is off, exactly like
///   translations. A new look-up of the same word and languages updates
///   that entry (`HistoryRepository.add`). [toggleFavorite] stars the shown
///   entry. History errors never fail a look-up.
/// * The engine follows the app's AI engine ([setEngine], [updateEngines])
///   until the user picks one for the dictionary ([pickEngine]), which is
///   then kept while it is available (not saved: like Proofread's model).
/// * The language of a shown entry ([DictionaryState.entryLanguage], e.g.
///   to read it aloud) is the chosen source language; when the source is
///   detected, a script only one language uses tells it, else the
///   optional `identifyLanguage` (the on-device identifier, nothing is
///   sent anywhere) looks at the headword, the examples and the synonyms.
class DictionaryCubit extends Cubit<DictionaryState> {
  new({
    required this._repository,
    TranslationEngine? engine,
    String word = '',
    Language source = Language.auto,
    Language target = const Language(code: 'en', name: 'English'),
    DictionaryVerbosity verbosity = DictionaryVerbosity.standard,
    this._uiLanguage = 'English',
    this._offlineName = offlineEngineDefaultName,
    this._usageTracker,
    this._history,
    this._settings,
    this._identifyLanguage,
    this._offlineDictionary,
    DateTime Function()? clock,
  }) : _clock = clock ?? DateTime.now,
       super(
         DictionaryState(
           word: _cut(word),
           source: source.isCustom ? Language.auto : source,
           target: target.isAuto || target.isCustom ? _english : target,
           engine: _usable(engine),
           verbosity: verbosity,
         ),
       ) {
    final offline = _offlineDictionary;
    if (offline == null) return;
    _offlineLoaded = _loadOffline(offline);
    _offlineChanges = offline.changes.listen(
      (_) => _offlineLoaded = _loadOffline(offline),
    );
  }

  /// Longest word or phrase looked up; longer text is cut (a dictionary is
  /// for words, and links are not trusted).
  static const maxWordLength = 100;

  /// Longest [historySummary]; a longer one is cut and ends with `…`.
  static const maxSummaryLength = 300;

  /// Prefix of the ids of the history entries of look-ups (they never
  /// collide with the ids of translations).
  static const historyIdPrefix = 'dictionary:';

  static const _english = Language(code: 'en', name: 'English');

  /// Control, line separator and bidi control characters: words from model
  /// output ([lookUpWord]) must stay one plain line.
  static final _unsafe = RegExp(
    r'[\x00-\x1F\x7F-\x9F\u2028\u2029\u200E\u200F\u202A-\u202E\u2066-\u2069]',
  );

  final TranslationRepository _repository;
  final String _uiLanguage;

  /// The name of [offlineEngine] for dictionaries without a source, in the
  /// UI language (it is kept in the history).
  final String _offlineName;
  final UsageTracker? _usageTracker;
  final HistoryCubit? _history;
  final SettingsCubit? _settings;
  final DateTime Function() _clock;

  /// Identifies the language of a text on the device (null: unknown).
  final Future<String?> Function(String text)? _identifyLanguage;

  /// The installed offline dictionaries (null: AI only).
  final OfflineDictionary? _offlineDictionary;

  /// [DictionaryState.offlineLanguages] is being read.
  Future<void>? _offlineLoaded;
  StreamSubscription<void>? _offlineChanges;

  /// The latest request (shown, loading or failed) went to the AI engine.
  bool _aiRequest = false;

  /// The "engine" of entries from offline dictionaries, for the history:
  /// named after their source ([DictionaryAttribution.source]), else
  /// [name] (the cubit's is in the UI language).
  static TranslationEngine offlineEngine(
    DictionaryAttribution attribution, {
    String name = offlineEngineDefaultName,
  }) => TranslationEngine(
    id: offlineEngineId,
    kind: EngineKind.offline,
    name: attribution.source.trim().isEmpty ? name : attribution.source.trim(),
    isLocal: true,
  );

  /// The English name of [offlineEngine] for dictionaries without a source.
  static const offlineEngineDefaultName = 'Offline dictionary';

  /// Id of [offlineEngine].
  static const offlineEngineId = 'dictionary:offline';

  /// Id of the engine the user picked ([pickEngine]).
  String? _pickedEngineId;

  /// The engine that wrote the shown entry (for [toggleFavorite]).
  TranslationEngine? _entryEngine;

  /// Incremented per look-up so stale responses are ignored.
  int _request = 0;

  /// [lookUp] was called while no engine was available.
  bool _pending = false;

  /// The last [toggleFavorite] (taps run one after the other).
  Future<void> _favorite = Future.value();

  static TranslationEngine? _usable(TranslationEngine? engine) =>
      engine != null && engine.supportsExtras ? engine : null;

  /// [text] cut to [maxWordLength] UTF-16 units without splitting a
  /// surrogate pair.
  static String _cut(String text, [int maxLength = maxWordLength]) {
    if (text.length <= maxLength) return text;
    var end = maxLength;
    final last = text.codeUnitAt(end - 1);
    if (last >= 0xD800 && last <= 0xDBFF) end--;
    return text.substring(0, end);
  }

  /// [text] on one line, without control or bidi characters.
  static String _oneLine(String text) =>
      text.replaceAll(_unsafe, ' ').replaceAll(RegExp(r'\s+'), ' ').trim();

  /// What the history keeps of [entry]: the part of speech and the first
  /// definition ("noun · A small domesticated feline."), else the first
  /// translation, else an empty string. One line of at most
  /// [maxSummaryLength] characters.
  static String historySummary(DictionaryEntry entry) {
    for (final sense in entry.senses) {
      final definition = _oneLine(sense.definition);
      if (definition.isEmpty) continue;
      final partOfSpeech = _oneLine(
        sense.partOfSpeech.trim().isNotEmpty
            ? sense.partOfSpeech
            : entry.partsOfSpeech.firstOrNull ?? '',
      );
      return _summary(
        partOfSpeech.isEmpty ? definition : '$partOfSpeech · $definition',
      );
    }
    for (final sense in entry.senses) {
      for (final translation in sense.translations) {
        final clean = _oneLine(translation);
        if (clean.isNotEmpty) return _summary(clean);
      }
    }
    return '';
  }

  static String _summary(String text) => text.length <= maxSummaryLength
      ? text
      : '${_cut(text, maxSummaryLength - 1).trimRight()}…';

  /// Uses [engine] for look-ups (null, or an engine without AI extras,
  /// means none is available). Runs a look-up that was waiting for it.
  void setEngine(TranslationEngine? engine) {
    final usable = _usable(engine);
    if (!identical(usable, state.engine)) {
      emit(state.copyWith(engine: () => usable));
    }
    if (usable != null && _pending) unawaited(lookUp());
  }

  /// Uses [engine] for look-ups from now on, also when the app's AI engine
  /// changes later ([updateEngines]), as long as it is available. The
  /// shown (or loading) word is looked up again with it.
  void pickEngine(TranslationEngine engine) {
    final usable = _usable(engine);
    if (usable == null) return;
    _pickedEngineId = usable.id;
    if (usable.id == state.engine?.id) {
      setEngine(usable);
      return;
    }
    setEngine(usable);
    _refresh(engineChanged: true);
  }

  /// The app's engines changed: uses the engine the user picked
  /// ([pickEngine]) while [engines] still has it (refreshing its details),
  /// else [preferred] (the app's AI engine for the dictionary).
  void updateEngines(
    List<TranslationEngine> engines, {
    TranslationEngine? preferred,
  }) {
    final picked = _pickedEngineId;
    if (picked != null) {
      for (final engine in engines) {
        if (engine.id == picked && _usable(engine) != null) {
          setEngine(engine);
          return;
        }
      }
      _pickedEngineId = null;
    }
    setEngine(preferred);
  }

  /// The user typed [word] (cut to [maxWordLength]).
  void setWord(String word) {
    _pending = false;
    final cut = _cut(word);
    if (cut == state.word) return;
    emit(state.copyWith(word: cut));
  }

  void setSource(Language language) {
    if (language == state.source || language.isCustom) return;
    emit(state.copyWith(source: language));
    _refresh();
  }

  void setTarget(Language language) {
    if (language == state.target || language.isAuto || language.isCustom) {
      return;
    }
    emit(state.copyWith(target: language));
    _refresh();
  }

  /// Sets how much a look-up asks for. The shown (or loading) entry is
  /// looked up again with it; without one nothing is requested, the level
  /// is used by the next look-up.
  Future<void> setVerbosity(DictionaryVerbosity verbosity) {
    if (verbosity == state.verbosity) return Future.value();
    emit(state.copyWith(verbosity: verbosity));
    final shown =
        state.status == DictionaryStatus.loading ||
        state.status == DictionaryStatus.success;
    final engine = state.engine;
    final word = state.lookedUp;
    if (!shown || engine == null || word.isEmpty || !_aiRequest) {
      return Future.value();
    }
    return _lookUp(engine, word);
  }

  /// Looks [word] up instead of the typed word, keeping the languages: a
  /// related word or the suggested spelling ("Did you mean …?") of an
  /// entry. The search field shows it. As it comes from model output it is
  /// reduced to one line without control or bidi characters and cut to
  /// [maxWordLength]; a blank word is ignored.
  Future<void> lookUpWord(String word) {
    final clean = _cut(
      word.replaceAll(_unsafe, ' ').replaceAll(RegExp(r'\s+'), ' ').trim(),
    ).trimRight();
    if (clean.isEmpty) return Future.value();
    setWord(clean);
    return lookUp();
  }

  /// Looks [word] up from [source] into [target] with [verbosity] (null
  /// keeps the current language or level): a look-up asked for from
  /// elsewhere, such as a History entry, while the dictionary is open.
  /// Unlike [setSource], [setTarget] and [setVerbosity] in a row, it
  /// requests the entry once. Languages the dictionary cannot use (a custom
  /// language, an auto target) are ignored; the word is cut to
  /// [maxWordLength].
  Future<void> open(
    String word, {
    Language? source,
    Language? target,
    DictionaryVerbosity? verbosity,
  }) {
    _pending = false;
    emit(
      state.copyWith(
        word: _cut(word.trim()),
        source: source == null || source.isCustom ? null : source,
        target: target == null || target.isAuto || target.isCustom
            ? null
            : target,
        verbosity: verbosity,
      ),
    );
    return lookUp();
  }

  /// Adds the shown entry to the favorites, or takes it out: toggles the
  /// favorite of its look-up in the history (`HistoryState.lookUpOf`), or
  /// saves the look-up as a favorite when the history does not have it
  /// (also with history off or in incognito: starring is an explicit save,
  /// as for translations). Does nothing without a shown entry (or a
  /// history).
  ///
  /// A toggle starts once the previous one is done, so a quick second tap
  /// (before the new favorite is in the history) takes it out again
  /// rather than saving it twice.
  Future<void> toggleFavorite() {
    final next = _favorite.then((_) => _toggleFavorite());
    return _favorite = next;
  }

  Future<void> _toggleFavorite() async {
    final history = _history;
    final entry = state.entry;
    final engine = _entryEngine;
    if (history == null ||
        state.status != DictionaryStatus.success ||
        entry == null ||
        state.isEmptyEntry ||
        engine == null) {
      return;
    }
    final saved = history.state.lookUpOf(
      state.lookedUp,
      source: state.source,
      target: state.target,
    );
    try {
      if (saved != null) {
        await history.toggleFavorite(saved.id);
      } else {
        await history.add(
          _historyEntry(
            engine,
            entry,
            word: state.lookedUp,
            source: state.source,
            target: state.target,
            verbosity: state.verbosity,
            isFavorite: true,
          ),
        );
      }
    } on Object catch (error, stackTrace) {
      addError(error, stackTrace);
    }
  }

  /// Swaps the word's language and the translations' language.
  void swap() {
    if (!state.canSwap) return;
    emit(state.copyWith(source: state.target, target: state.source));
    _refresh();
  }

  /// Clears the word and the entry.
  void clear() {
    _pending = false;
    _request++;
    emit(
      state.copyWith(
        word: '',
        status: DictionaryStatus.idle,
        entry: () => null,
        lookedUp: '',
        error: () => null,
        entryLanguage: () => null,
        offlineAnswer: () => null,
        suggestions: const [],
      ),
    );
  }

  /// Leaves the entry (or the look-up in progress, or its error) for the
  /// search, keeping the word: the status is idle again and a pending
  /// response is ignored.
  void closeEntry() {
    _pending = false;
    _request++;
    emit(
      state.copyWith(
        status: DictionaryStatus.idle,
        entry: () => null,
        lookedUp: '',
        error: () => null,
        entryLanguage: () => null,
        offlineAnswer: () => null,
        suggestions: const [],
      ),
    );
  }

  /// Looks the current word up with the current [DictionaryState.verbosity]:
  /// in the offline dictionaries first when some are installed, else with
  /// the AI engine. Without either the look-up waits for [setEngine].
  Future<void> lookUp() async {
    final word = state.word.trim();
    if (word.isEmpty) return;
    final offline = _offlineDictionary;
    if (offline != null) {
      await _offlineLoaded;
      if (isClosed) return;
      if (state.hasOfflineDictionaries) {
        await _lookUpOffline(offline, word);
        return;
      }
    }
    final engine = state.engine;
    if (engine == null) {
      _pending = true;
      return;
    }
    await _lookUp(engine, word);
  }

  /// Asks the AI engine about the shown (or typed) word: "More detail"
  /// under an entry from an offline dictionary. Nothing without an engine.
  Future<void> moreDetail() {
    final engine = state.engine;
    final word = state.lookedUp.isNotEmpty ? state.lookedUp : state.word.trim();
    if (engine == null || word.isEmpty) return Future.value();
    return _lookUp(engine, word);
  }

  /// Repeats the latest look-up: [moreDetail] when it went to the AI
  /// engine (after an offline entry, the AI is asked again), else [lookUp].
  Future<void> retry() =>
      _aiRequest && state.engine != null && state.lookedUp.isNotEmpty
      ? _lookUp(state.engine!, state.lookedUp)
      : lookUp();

  /// Looks [word] up in [offline] (the language of the word, or every
  /// dictionary while it is detected), then with the AI engine when the
  /// dictionaries do not have it.
  Future<void> _lookUpOffline(OfflineDictionary offline, String word) async {
    final source = state.source;
    final target = state.target;
    final verbosity = state.verbosity;
    _pending = false;
    _aiRequest = false;
    final request = ++_request;
    emit(
      state.copyWith(
        status: DictionaryStatus.loading,
        entry: () => null,
        lookedUp: word,
        error: () => null,
        entryLanguage: () => null,
        offlineAnswer: () => null,
        suggestions: const [],
      ),
    );
    final answer = await _offlineAnswer(offline, word, source, target);
    if (isClosed || request != _request) return;
    if (answer != null) {
      final engine = offlineEngine(answer.attribution, name: _offlineName);
      final language = source.isAuto ? answer.language : source.code;
      _entryEngine = engine;
      emit(
        state.copyWith(
          status: DictionaryStatus.success,
          entry: () => answer.entry,
          entryLanguage: () => language,
          offlineAnswer: () => answer,
        ),
      );
      if (!state.isEmptyEntry) {
        _record(
          engine,
          answer.entry,
          word: word,
          source: source,
          target: target,
          verbosity: verbosity,
        );
      }
      return;
    }
    final engine = state.engine;
    if (engine != null) {
      await _lookUp(engine, word);
      return;
    }
    final suggestions = await _suggest(offline, word, source);
    if (isClosed || request != _request) return;
    emit(
      state.copyWith(
        status: DictionaryStatus.success,
        suggestions: suggestions,
      ),
    );
  }

  /// [offline]'s answer for [word], or null (also when it fails: an
  /// unreadable dictionary answers nothing). A method of its own so that no
  /// nullable local set in a `try` is read in a closure (dart2js got such
  /// locals wrong).
  Future<OfflineDictionaryAnswer?> _offlineAnswer(
    OfflineDictionary offline,
    String word,
    Language source,
    Language target,
  ) async {
    try {
      return await offline.lookUp(
        word,
        language: source.isAuto ? null : source.code,
        target: target.code,
      );
    } on Object catch (error, stackTrace) {
      addError(error, stackTrace);
      return null;
    }
  }

  /// Words of the dictionaries that start like [word] (or, without any,
  /// like [word] without its last letter), other than [word] itself.
  Future<List<String>> _suggest(
    OfflineDictionary offline,
    String word,
    Language source,
  ) async {
    final language = source.isAuto ? null : source.code;
    final lower = word.toLowerCase();
    try {
      for (final prefix in [
        word,
        if (word.runes.length > 2)
          String.fromCharCodes(word.runes.take(word.runes.length - 1)),
      ]) {
        final words = [
          for (final suggestion in await offline.suggest(
            prefix,
            language: language,
            limit: maxSuggestions + 1,
          ))
            if (suggestion.toLowerCase() != lower) suggestion,
        ].take(maxSuggestions).toList();
        if (words.isNotEmpty) return words;
      }
    } on Object catch (error, stackTrace) {
      addError(error, stackTrace);
    }
    return const [];
  }

  /// Most [DictionaryState.suggestions].
  static const maxSuggestions = 6;

  /// Reads the languages of the installed offline dictionaries.
  Future<void> _loadOffline(OfflineDictionary offline) async {
    List<String> languages;
    try {
      languages = List.unmodifiable(await offline.installedLanguages());
    } on Object catch (error, stackTrace) {
      addError(error, stackTrace);
      languages = const [];
    }
    if (isClosed) return;
    emit(state.copyWith(offlineLanguages: languages));
    if (_pending && state.hasOfflineDictionaries) unawaited(lookUp());
  }

  /// Looks [word] up with [engine] and the current verbosity.
  Future<void> _lookUp(TranslationEngine engine, String word) async {
    final verbosity = state.verbosity;
    final source = state.source;
    final target = state.target;
    _pending = false;
    _aiRequest = true;
    final request = ++_request;
    emit(
      state.copyWith(
        status: DictionaryStatus.loading,
        entry: () => null,
        lookedUp: word,
        error: () => null,
        entryLanguage: () => null,
        offlineAnswer: () => null,
        suggestions: const [],
      ),
    );
    try {
      final entry = await _repository.lookUp(
        engine,
        word,
        source: source,
        target: target,
        uiLanguage: _uiLanguage,
        verbosity: verbosity,
      );
      _recordUsage(engine, word, entry);
      if (isClosed || request != _request) return;
      _entryEngine = engine;
      final known = source.isAuto ? dictionaryScriptLanguage(entry.word) : null;
      emit(
        state.copyWith(
          status: DictionaryStatus.success,
          entry: () => entry,
          entryLanguage: () => source.isAuto ? known : source.code,
        ),
      );
      if (source.isAuto && known == null) {
        unawaited(_identify(entry, request));
      }
      if (!state.isEmptyEntry) {
        _record(
          engine,
          entry,
          word: word,
          source: source,
          target: target,
          verbosity: verbosity,
        );
      }
    } on Object catch (error, stackTrace) {
      if (isClosed || request != _request) return;
      addError(error, stackTrace);
      emit(
        state.copyWith(status: DictionaryStatus.failure, error: () => error),
      );
    }
  }

  /// Sets [DictionaryState.entryLanguage] from the on-device identifier
  /// for [entry] (the look-up [request]): its headword, examples and
  /// synonyms are all in the word's language. Unknown codes and failures
  /// leave it unknown.
  Future<void> _identify(DictionaryEntry entry, int request) async {
    final identify = _identifyLanguage;
    if (identify == null) return;
    final text = [
      entry.word,
      for (final example in entry.examples) example.source,
      ...entry.synonyms,
      ...entry.relatedWords,
    ].map(_oneLine).where((part) => part.isNotEmpty).join('\n');
    String? code;
    try {
      code = (await identify(text))?.trim();
    } on Object {
      return;
    }
    if (isClosed || request != _request || code == null || code.isEmpty) {
      return;
    }
    if (LanguageCatalog.byCode(code) == null) return;
    emit(state.copyWith(entryLanguage: () => code));
  }

  /// Looks the word up again after a language change, once something was
  /// looked up; after an engine change ([engineChanged]) only an entry of
  /// the AI engine is.
  void _refresh({bool engineChanged = false}) {
    if (state.status == DictionaryStatus.idle) return;
    final offline = _offlineDictionary != null && state.hasOfflineDictionaries;
    final engine = state.engine;
    if (engineChanged) {
      final word = state.word.trim();
      if (!_aiRequest || engine == null || word.isEmpty) return;
      unawaited(_lookUp(engine, word));
      return;
    }
    if (engine == null && !offline) return;
    unawaited(lookUp());
  }

  @override
  Future<void> close() async {
    await _offlineChanges?.cancel();
    await super.close();
  }

  /// Saves the look-up of [word] in the history when history is on (see
  /// the class docs).
  void _record(
    TranslationEngine engine,
    DictionaryEntry entry, {
    required String word,
    required Language source,
    required Language target,
    required DictionaryVerbosity verbosity,
  }) {
    final history = _history;
    final settings = _settings?.state;
    if (history == null ||
        settings == null ||
        !settings.saveHistory ||
        settings.incognito) {
      return;
    }
    try {
      final saved = _historyEntry(
        engine,
        entry,
        word: word,
        source: source,
        target: target,
        verbosity: verbosity,
      );
      unawaited(history.add(saved).then((_) {}, onError: (Object _) {}));
    } on Object {
      // History must never break a look-up.
    }
  }

  /// The history entry of the look-up of [word] that found [entry].
  HistoryEntry _historyEntry(
    TranslationEngine engine,
    DictionaryEntry entry, {
    required String word,
    required Language source,
    required Language target,
    required DictionaryVerbosity verbosity,
    bool isFavorite = false,
  }) {
    final now = _clock();
    return HistoryEntry(
      id: '$historyIdPrefix${now.microsecondsSinceEpoch}',
      kind: HistoryEntryKind.dictionary,
      text: word,
      translation: historySummary(entry),
      source: source,
      target: target,
      engineId: engine.id,
      engineName: engine.name,
      createdAt: now,
      verbosity: verbosity,
      isFavorite: isFavorite,
    );
  }

  void _recordUsage(
    TranslationEngine engine,
    String word,
    DictionaryEntry entry,
  ) {
    final tracker = _usageTracker;
    final providerId = engine.providerId;
    if (tracker == null || providerId == null || providerId.isEmpty) return;
    final output = [
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
    ].where((part) => part.isNotEmpty).join('\n');
    try {
      unawaited(
        tracker
            .recordText(providerId, input: word, output: output)
            .then((_) {}, onError: (Object _) {}),
      );
    } on Object {
      // Usage counting must never break a look-up.
    }
  }
}

/// Scripts that one language alone uses, with that language's code.
final _scripts = <(RegExp, String)>[
  (RegExp('[\u3040-\u30FF]'), 'ja'), // Hiragana, Katakana.
  (RegExp('[\uAC00-\uD7AF\u1100-\u11FF]'), 'ko'), // Hangul.
  (RegExp('[\u0E00-\u0E7F]'), 'th'),
  (RegExp('[\u0370-\u03FF]'), 'el'),
  (RegExp('[\u10A0-\u10FF]'), 'ka'),
  (RegExp('[\u0530-\u058F]'), 'hy'),
  (RegExp('[\u0B80-\u0BFF]'), 'ta'),
  (RegExp('[\u0C00-\u0C7F]'), 'te'),
  (RegExp('[\u0C80-\u0CFF]'), 'kn'),
  (RegExp('[\u0D00-\u0D7F]'), 'ml'),
  (RegExp('[\u0A80-\u0AFF]'), 'gu'),
  (RegExp('[\u0A00-\u0A7F]'), 'pa'),
  (RegExp('[\u0D80-\u0DFF]'), 'si'),
  (RegExp('[\u1780-\u17FF]'), 'km'),
  (RegExp('[\u0E80-\u0EFF]'), 'lo'),
  (RegExp('[\u1000-\u109F]'), 'my'),
];

/// The language of [word] when it is written in a script that one
/// language alone uses (Japanese kana, Hangul, Thai, Greek, Georgian,
/// Armenian, several Indic scripts, Sinhala, Khmer, Lao, Myanmar), else
/// null (Latin, Cyrillic, Arabic, Han and other shared scripts).
String? dictionaryScriptLanguage(String word) {
  for (final (script, code) in _scripts) {
    if (script.hasMatch(word)) return code;
  }
  return null;
}
