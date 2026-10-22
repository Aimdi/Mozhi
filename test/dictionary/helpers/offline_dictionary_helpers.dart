import 'dart:async';

import 'package:translation_repository/translation_repository.dart';

const wiktionary = DictionaryAttribution(
  source: 'Wiktionary',
  sourceUrl: 'https://en.wiktionary.org/',
  license: 'CC BY-SA 4.0',
  licenseUrl: 'https://creativecommons.org/licenses/by-sa/4.0/',
  text: 'Spanish entries from Wiktionary, by its contributors.',
  snapshot: '2026-10-01',
);

const gatoPackEntry = DictionaryEntry(
  word: 'gato',
  pronunciation: 'ˈɡato',
  partsOfSpeech: ['noun'],
  senses: [
    DictionarySense(
      definition: 'cat',
      partOfSpeech: 'noun',
      usage: 'masculine',
    ),
  ],
  examples: [
    DictionaryExample(
      source: 'El gato duerme.',
      translation: 'The cat sleeps.',
    ),
  ],
  synonyms: ['minino'],
);

/// The Spanish dictionary's answer for `gato`.
const gatoAnswer = OfflineDictionaryAnswer(
  entry: gatoPackEntry,
  language: 'es',
  attribution: wiktionary,
);

/// The answer for `gatos`: the entry of `gato`.
const gatosAnswer = OfflineDictionaryAnswer(
  entry: gatoPackEntry,
  language: 'es',
  attribution: wiktionary,
  inflectedForm: 'gatos',
  otherLemmas: ['gatear'],
);

/// An [OfflineDictionary] with [languages] installed that answers from
/// [answers] (by word) and suggests [suggestions] (by prefix), recording
/// its calls.
class FakeOfflineDictionary implements OfflineDictionary {
  new({
    this.languages = const ['es'],
    this.answers = const {'gato': gatoAnswer, 'gatos': gatosAnswer},
    this.suggestions = const {},
  });

  List<String> languages;
  Map<String, OfflineDictionaryAnswer> answers;
  Map<String, List<String>> suggestions;

  /// Look-ups wait for it when set.
  Completer<void>? gate;

  /// Thrown by every call when set.
  Error? error;

  final lookUps = <({String word, String? language, String? target})>[];
  final suggested = <({String prefix, String? language})>[];
  final _changes = StreamController<void>.broadcast();

  /// Installs [codes] and tells the listeners.
  void install(List<String> codes) {
    languages = codes;
    _changes.add(null);
  }

  @override
  Stream<void> get changes => _changes.stream;

  @override
  Future<List<String>> installedLanguages() async {
    if (error case final error?) throw error;
    return languages;
  }

  @override
  Future<OfflineDictionaryAnswer?> lookUp(
    String word, {
    String? language,
    String? target,
  }) async {
    lookUps.add((word: word, language: language, target: target));
    await gate?.future;
    if (error case final error?) throw error;
    if (language != null && !languages.any((code) => code == language)) {
      return null;
    }
    return answers[word];
  }

  @override
  Future<List<String>> suggest(
    String prefix, {
    String? language,
    int limit = 8,
  }) async {
    suggested.add((prefix: prefix, language: language));
    if (error case final error?) throw error;
    return (suggestions[prefix] ?? const []).take(limit).toList();
  }
}
