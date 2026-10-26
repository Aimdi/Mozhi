import 'package:bloc/bloc.dart';
import 'package:mozhi/word_lookup/cubit/word_lookup_state.dart';
import 'package:mozhi/word_lookup/data/word_lookup_service.dart';
import 'package:translation_repository/translation_repository.dart';

export 'word_lookup_state.dart';

/// Drives the word card ([WordLookupState]) of a word tapped in a
/// translation.
///
/// * [load] asks the installed offline dictionaries
///   ([WordLookupService.lookUpOffline]); nothing leaves the device. The
///   card then shows their entry ([WordLookupStatus.found]), says they
///   don't have the word ([WordLookupStatus.notFound]) or that no
///   dictionary of its language is installed
///   ([WordLookupStatus.noDictionary]). A dictionary that fails reads as
///   not having the word.
/// * Only [lookUpOnline] (the user's tap on "Look up with …") asks the
///   dictionary engine (an AI model, [WordLookupService.lookUpOnline]),
///   with the sentence as context; the privacy settings may stop it
///   ([WordLookupOnlineStatus.failure] with a `ConsentRequiredException`,
///   retried with [lookUpOnline] once the user agreed). Nothing else
///   starts a request.
/// * [lookUpWord] shows another word (the lemma of an inflected form).
///
/// Look-ups are not saved to the history; the word is cut to
/// [maxWordLength] and reduced to one line.
class WordLookupCubit extends Cubit<WordLookupState> {
  new({
    required this._service,
    required String word,
    required Language language,
    Language? into,
    String sentence = '',
    TranslationEngine? engine,
    this._uiLanguage = 'English',
  }) : super(
         WordLookupState(
           word: clean(word),
           language: language,
           into: into == null || into.isAuto || into.isCustom ? null : into,
           sentence: clean(sentence, maxLength: maxSentenceLength),
           engine: engine != null && engine.supportsExtras ? engine : null,
         ),
       );

  /// Longest word looked up (as the Dictionary tab's).
  static const maxWordLength = 100;

  /// Longest sentence sent along with an explicit look-up.
  static const maxSentenceLength = 400;

  static const _english = Language(code: 'en', name: 'English');

  /// Control, line separator and bidi control characters.
  static final _unsafe = RegExp(
    r'[\x00-\x1F\x7F-\x9F\u2028\u2029\u200E\u200F\u202A-\u202E\u2066-\u2069]',
  );

  final WordLookupService _service;
  final String _uiLanguage;

  /// Incremented per look-up so stale answers are ignored.
  int _request = 0;

  /// [text] on one line, without control or bidi characters, trimmed and
  /// cut to [maxLength] code units (never inside a surrogate pair).
  static String clean(String text, {int maxLength = maxWordLength}) {
    final line = text
        .replaceAll(_unsafe, ' ')
        .replaceAll(RegExp(r'\s+'), ' ')
        .trim();
    if (line.length <= maxLength) return line;
    var end = maxLength;
    final last = line.codeUnitAt(end - 1);
    if (last >= 0xD800 && last <= 0xDBFF) end--;
    return line.substring(0, end).trimRight();
  }

  /// Looks the word up in the installed offline dictionaries.
  Future<void> load() async {
    final word = state.word;
    final request = ++_request;
    emit(
      state.copyWith(
        status: WordLookupStatus.loading,
        offlineAnswer: () => null,
        onlineStatus: WordLookupOnlineStatus.idle,
        onlineEntry: () => null,
        error: () => null,
      ),
    );
    if (word.isEmpty) {
      emit(state.copyWith(status: WordLookupStatus.notFound));
      return;
    }
    final hasDictionary = await _service.hasDictionaryFor(state.language);
    if (isClosed || request != _request) return;
    if (!hasDictionary) {
      emit(state.copyWith(status: WordLookupStatus.noDictionary));
      return;
    }
    final answer = await _offlineAnswer(word);
    if (isClosed || request != _request) return;
    emit(
      state.copyWith(
        status: answer == null
            ? WordLookupStatus.notFound
            : WordLookupStatus.found,
        offlineAnswer: () => answer,
      ),
    );
  }

  /// The offline dictionaries' answer for [word], or null (also when they
  /// fail).
  Future<OfflineDictionaryAnswer?> _offlineAnswer(String word) async {
    try {
      return await _service.lookUpOffline(
        word,
        language: state.language,
        into: state.into,
      );
    } on Object catch (error, stackTrace) {
      addError(error, stackTrace);
      return null;
    }
  }

  /// Shows [word] instead (e.g. the lemma of an inflected form), looked up
  /// offline like the first word. A blank word is ignored.
  Future<void> lookUpWord(String word) {
    final cleaned = clean(word);
    if (cleaned.isEmpty) return Future.value();
    emit(state.copyWith(word: cleaned));
    return load();
  }

  /// Asks the dictionary engine about the word: only when the user taps
  /// "Look up with …" (or retries after agreeing to send it). Does nothing
  /// without an engine.
  Future<void> lookUpOnline() async {
    final engine = state.engine;
    final word = state.word;
    if (engine == null || word.isEmpty) return;
    final request = ++_request;
    emit(
      state.copyWith(
        onlineStatus: WordLookupOnlineStatus.loading,
        onlineEntry: () => null,
        error: () => null,
      ),
    );
    try {
      final entry = await _service.lookUpOnline(
        engine,
        word,
        language: state.language,
        into: state.into ?? _english,
        sentence: state.sentence,
        uiLanguage: _uiLanguage,
      );
      if (isClosed || request != _request) return;
      emit(
        state.copyWith(
          onlineStatus: WordLookupOnlineStatus.done,
          onlineEntry: () => entry,
        ),
      );
    } on Object catch (error, stackTrace) {
      if (isClosed || request != _request) return;
      addError(error, stackTrace);
      emit(
        state.copyWith(
          onlineStatus: WordLookupOnlineStatus.failure,
          error: () => error,
        ),
      );
    }
  }
}
