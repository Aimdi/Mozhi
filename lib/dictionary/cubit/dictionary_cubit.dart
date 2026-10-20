import 'dart:async';

import 'package:bloc/bloc.dart';
import 'package:mozhi/dictionary/cubit/dictionary_state.dart';
import 'package:mozhi/history/cubit/history_cubit.dart';
import 'package:mozhi/history/models/history_entry.dart';
import 'package:mozhi/settings/cubit/settings_cubit.dart';
import 'package:mozhi/usage/data/usage_tracker.dart';
import 'package:translation_repository/translation_repository.dart';

export 'dictionary_state.dart';

/// Drives the dictionary page: looks words up with an AI engine
/// ([TranslationRepository.lookUp]).
///
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
class DictionaryCubit extends Cubit<DictionaryState> {
  new({
    required this._repository,
    TranslationEngine? engine,
    String word = '',
    Language source = Language.auto,
    Language target = const Language(code: 'en', name: 'English'),
    DictionaryVerbosity verbosity = DictionaryVerbosity.standard,
    this._uiLanguage = 'English',
    this._usageTracker,
    this._history,
    this._settings,
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
       );

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
  final UsageTracker? _usageTracker;
  final HistoryCubit? _history;
  final SettingsCubit? _settings;
  final DateTime Function() _clock;

  /// The engine that wrote the shown entry (for [toggleFavorite]).
  TranslationEngine? _entryEngine;

  /// Incremented per look-up so stale responses are ignored.
  int _request = 0;

  /// [lookUp] was called while no engine was available.
  bool _pending = false;

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
    if (!shown || engine == null || word.isEmpty) return Future.value();
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

  /// Adds the shown entry to the favourites, or takes it out: toggles the
  /// favourite of its look-up in the history (`HistoryState.lookUpOf`), or
  /// saves the look-up as a favourite when the history does not have it
  /// (also with history off or in incognito: starring is an explicit save,
  /// as for translations). Does nothing without a shown entry (or a
  /// history).
  Future<void> toggleFavorite() async {
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
      ),
    );
  }

  /// Looks the current word up with the current [DictionaryState.verbosity].
  /// Without an engine the look-up waits for [setEngine].
  Future<void> lookUp() async {
    final word = state.word.trim();
    if (word.isEmpty) return;
    final engine = state.engine;
    if (engine == null) {
      _pending = true;
      return;
    }
    await _lookUp(engine, word);
  }

  /// Looks [word] up with [engine] and the current verbosity.
  Future<void> _lookUp(TranslationEngine engine, String word) async {
    final verbosity = state.verbosity;
    final source = state.source;
    final target = state.target;
    _pending = false;
    final request = ++_request;
    emit(
      state.copyWith(
        status: DictionaryStatus.loading,
        entry: () => null,
        lookedUp: word,
        error: () => null,
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
      emit(
        state.copyWith(status: DictionaryStatus.success, entry: () => entry),
      );
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

  /// Looks the word up again after a language change, once something was
  /// looked up.
  void _refresh() {
    if (state.status == DictionaryStatus.idle || state.engine == null) return;
    unawaited(lookUp());
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
