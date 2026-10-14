import 'dart:async';

import 'package:bloc/bloc.dart';
import 'package:mozhi/dictionary/cubit/dictionary_state.dart';
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
///   up (the user asked for a word already); nothing else starts a request
///   on its own.
/// * Finished requests to a bring-your-own-key provider are counted by the
///   optional `usageTracker`; tracker errors are ignored.
class DictionaryCubit extends Cubit<DictionaryState> {
  new({
    required this._repository,
    TranslationEngine? engine,
    String word = '',
    Language source = Language.auto,
    Language target = const Language(code: 'en', name: 'English'),
    this._uiLanguage = 'English',
    this._usageTracker,
  }) : super(
         DictionaryState(
           word: _cut(word),
           source: source.isCustom ? Language.auto : source,
           target: target.isAuto || target.isCustom ? _english : target,
           engine: _usable(engine),
         ),
       );

  /// Longest word or phrase looked up; longer text is cut (a dictionary is
  /// for words, and links are not trusted).
  static const maxWordLength = 100;

  static const _english = Language(code: 'en', name: 'English');

  final TranslationRepository _repository;
  final String _uiLanguage;
  final UsageTracker? _usageTracker;

  /// Incremented per look-up so stale responses are ignored.
  int _request = 0;

  /// [lookUp] was called while no engine was available.
  bool _pending = false;

  static TranslationEngine? _usable(TranslationEngine? engine) =>
      engine != null && engine.supportsExtras ? engine : null;

  /// [text] cut to [maxWordLength] UTF-16 units without splitting a
  /// surrogate pair.
  static String _cut(String text) {
    if (text.length <= maxWordLength) return text;
    var end = maxWordLength;
    final last = text.codeUnitAt(end - 1);
    if (last >= 0xD800 && last <= 0xDBFF) end--;
    return text.substring(0, end);
  }

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

  /// Looks the current word up. Without an engine the look-up waits for
  /// [setEngine].
  Future<void> lookUp() async {
    final word = state.word.trim();
    if (word.isEmpty) return;
    final engine = state.engine;
    if (engine == null) {
      _pending = true;
      return;
    }
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
        source: state.source,
        target: state.target,
        uiLanguage: _uiLanguage,
      );
      _recordUsage(engine, word, entry);
      if (isClosed || request != _request) return;
      emit(
        state.copyWith(status: DictionaryStatus.success, entry: () => entry),
      );
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
