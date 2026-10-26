import 'dart:async';

import 'package:mozhi/usage/data/usage_tracker.dart';
import 'package:mozhi/word_lookup/data/word_segmenter.dart';
import 'package:translation_repository/translation_repository.dart';

/// Looks up a word tapped in a translation: in the installed offline
/// dictionaries ([OfflineDictionary], the Dictionary tab's packs: nothing
/// leaves the device, nothing is logged) and, only when the user asks for
/// it, with a dictionary engine ([lookUpOnline]: an AI model through
/// [TranslationRepository.lookUp], under the privacy settings and consent
/// prompts as every request).
///
/// Also finds the word at a position of a text ([wordAt]): in scripts
/// written without spaces with the words of the installed dictionary of
/// the text's language ([indexFor]).
class WordLookupService {
  new({this.repository, this.offlineDictionary, this.usageTracker});

  /// Sends the explicit look-ups ([lookUpOnline]); null: offline only.
  final TranslationRepository? repository;

  /// The installed dictionary packs; null: none on this platform.
  final OfflineDictionary? offlineDictionary;

  /// Counts the explicit look-ups of bring-your-own-key providers.
  final UsageTracker? usageTracker;

  /// The dictionary language of [language] (null for "Detect language" and
  /// custom languages: every installed dictionary).
  static String? dictionaryCode(Language language) =>
      language.isAuto || language.isCustom ? null : language.code;

  /// Whether an installed dictionary has the words of [language] (any
  /// dictionary for "Detect language" or a custom language). False when
  /// there is none or they cannot be listed.
  Future<bool> hasDictionaryFor(Language language) async {
    final offline = offlineDictionary;
    if (offline == null) return false;
    final List<String> installed;
    try {
      installed = await offline.installedLanguages();
    } on Object {
      return false;
    }
    final code = dictionaryCode(language);
    if (code == null) return installed.isNotEmpty;
    return installed.any((pack) => dictionaryLanguageMatches(pack, code));
  }

  /// An elided article or pronoun before an apostrophe (French `l’homme`,
  /// Italian `dell’anno`, ...) and the word after it.
  static final _elision = RegExp(
    r"^\p{L}{1,4}['’ʼ](\p{L}{2,})$",
    unicode: true,
  );

  /// The installed dictionaries' entry for [word] in [language], with
  /// translations into [into] when they have them; null when they don't
  /// have it (or there are none). A word after an elided article or
  /// pronoun (`l’homme`) is looked up without it when the dictionaries
  /// don't have the whole. Throws what the dictionary throws.
  Future<OfflineDictionaryAnswer?> lookUpOffline(
    String word, {
    required Language language,
    Language? into,
  }) async {
    final offline = offlineDictionary;
    if (offline == null || word.trim().isEmpty) return null;
    Future<OfflineDictionaryAnswer?> find(String text) => offline.lookUp(
      text,
      language: dictionaryCode(language),
      target: into == null ? null : dictionaryCode(into),
    );
    final answer = await find(word);
    if (answer != null) return answer;
    final elided = _elision.firstMatch(word.trim())?.group(1);
    return elided == null ? null : await find(elided);
  }

  /// [engine]'s dictionary entry for [word] (in [language]), with
  /// translations into [into], definitions in [uiLanguage] and [sentence]
  /// as its context: one request, which the privacy settings may stop
  /// first (a [ConsentRequiredException]; nothing was sent then). A
  /// finished request is counted for bring-your-own-key providers.
  Future<DictionaryEntry> lookUpOnline(
    TranslationEngine engine,
    String word, {
    required Language language,
    required Language into,
    String sentence = '',
    String uiLanguage = 'English',
  }) async {
    final repository = this.repository;
    if (repository == null) {
      throw StateError('No translation repository for dictionary look-ups');
    }
    final entry = await repository.lookUp(
      engine,
      word,
      source: language.isCustom ? Language.auto : language,
      target: into,
      context: sentence,
      uiLanguage: uiLanguage,
      verbosity: DictionaryVerbosity.concise,
    );
    _recordUsage(engine, word, sentence, entry);
    return entry;
  }

  /// The words of the installed dictionary of [language], for
  /// [WordSegmenter.lookUpWordAt]; null without dictionaries.
  WordIndex? indexFor(Language language) {
    final offline = offlineDictionary;
    if (offline == null) return null;
    return _DictionaryWordIndex(offline, dictionaryCode(language));
  }

  /// The word of [text] at [offset] (see [WordSegmenter]): in Chinese,
  /// Japanese, Thai, Lao, Khmer and Myanmar the longest word of the
  /// installed dictionary of [language] there, else one character.
  Future<TextWord?> wordAt(
    String text,
    int offset, {
    required Language language,
  }) async {
    final plain = WordSegmenter.wordAt(text, offset);
    if (plain == null ||
        !WordSegmenter.writtenWithoutSpaces(plain.text) ||
        !await hasDictionaryFor(language)) {
      return plain;
    }
    return await WordSegmenter.lookUpWordAt(
      text,
      offset,
      index: indexFor(language),
    );
  }

  void _recordUsage(
    TranslationEngine engine,
    String word,
    String sentence,
    DictionaryEntry entry,
  ) {
    final tracker = usageTracker;
    final providerId = engine.providerId;
    if (tracker == null || providerId == null || providerId.isEmpty) return;
    final output = [
      entry.word,
      entry.pronunciation,
      ...entry.partsOfSpeech,
      for (final sense in entry.senses) ...[
        sense.definition,
        ...sense.translations,
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
            .recordText(providerId, input: '$word\n$sentence', output: output)
            .then((_) {}, onError: (Object _) {}),
      );
    } on Object {
      // Usage counting never breaks a look-up.
    }
  }
}

/// The words of the installed dictionaries of [_language] (null: all).
class _DictionaryWordIndex implements WordIndex {
  new(this._dictionary, this._language);

  final OfflineDictionary _dictionary;
  final String? _language;

  @override
  Future<bool> contains(String word) async {
    try {
      return await _dictionary.lookUp(word, language: _language) != null;
    } on Object {
      return false;
    }
  }

  @override
  Future<bool> hasPrefix(String prefix) async {
    try {
      final words = await _dictionary.suggest(
        prefix,
        language: _language,
        limit: 1,
      );
      return words.isNotEmpty;
    } on Object {
      return false;
    }
  }
}
