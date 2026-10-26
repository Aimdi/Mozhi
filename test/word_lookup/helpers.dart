import 'dart:async';

import 'package:mocktail/mocktail.dart';
import 'package:mozhi/usage/data/usage_tracker.dart';
import 'package:mozhi/word_lookup/data/word_lookup_service.dart';
import 'package:translation_repository/translation_repository.dart';

class MockTranslationRepository extends Mock implements TranslationRepository;

class MockUsageTracker extends Mock implements UsageTracker;

class MockWordLookupService extends Mock implements WordLookupService;

const english = Language(code: 'en', name: 'English');
const spanish = Language(code: 'es', name: 'Spanish');
const chinese = Language(code: 'zh', name: 'Chinese');

const wiktionary = DictionaryAttribution(
  source: 'Wiktionary',
  sourceUrl: 'https://en.wiktionary.org/',
  license: 'CC BY-SA 4.0',
  licenseUrl: 'https://creativecommons.org/licenses/by-sa/4.0/',
  text: 'Spanish entries from Wiktionary, by its contributors.',
);

const gatoEntry = DictionaryEntry(
  word: 'gato',
  pronunciation: 'ˈɡato',
  partsOfSpeech: ['noun'],
  senses: [
    DictionarySense(
      definition: 'cat',
      partOfSpeech: 'noun',
      translations: ['cat', 'tomcat'],
    ),
    DictionarySense(definition: 'jack (for lifting a car)'),
    DictionarySense(definition: 'sneak thief'),
    DictionarySense(definition: 'a dance'),
  ],
);

/// The Spanish dictionary's answer for `gato`.
const gatoAnswer = OfflineDictionaryAnswer(
  entry: gatoEntry,
  language: 'es',
  attribution: wiktionary,
);

/// The answer for `gatos`: the entry of `gato`, also a form of `gatear`.
const gatosAnswer = OfflineDictionaryAnswer(
  entry: gatoEntry,
  language: 'es',
  attribution: wiktionary,
  inflectedForm: 'gatos',
  otherLemmas: ['gatear'],
);

/// An AI model's entry for `gato`.
const aiGatoEntry = DictionaryEntry(
  word: 'gato',
  partsOfSpeech: ['noun'],
  senses: [
    DictionarySense(
      definition: 'A small domesticated feline.',
      translations: ['cat'],
    ),
  ],
  examples: [
    DictionaryExample(
      source: 'El gato duerme.',
      translation: 'The cat sleeps.',
    ),
  ],
);

const aiEngine = TranslationEngine(
  id: 'openai:gpt',
  kind: EngineKind.ai,
  name: 'GPT Mini',
  providerId: 'openai',
);

/// An [OfflineDictionary] with [languages] installed that answers from
/// [answers] (by word) and has the words of [words] (for suggestions),
/// recording its calls.
class FakeOfflineDictionary implements OfflineDictionary {
  new({
    this.languages = const ['es'],
    this.answers = const {'gato': gatoAnswer, 'gatos': gatosAnswer},
    this.words = const {},
  });

  List<String> languages;
  Map<String, OfflineDictionaryAnswer> answers;
  Set<String> words;

  /// Look-ups wait for it when set.
  Completer<void>? gate;

  /// Thrown by every call when set.
  Error? error;

  final lookUps = <({String word, String? language, String? target})>[];
  final _changes = StreamController<void>.broadcast();

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
    if (language != null && !languages.contains(language)) return null;
    if (answers[word] case final answer?) return answer;
    if (!words.contains(word)) return null;
    return OfflineDictionaryAnswer(
      entry: DictionaryEntry(word: word),
      language: language ?? languages.first,
      attribution: wiktionary,
    );
  }

  @override
  Future<List<String>> suggest(
    String prefix, {
    String? language,
    int limit = 8,
  }) async {
    if (error case final error?) throw error;
    return [
      for (final word in {...words, ...answers.keys})
        if (word.startsWith(prefix)) word,
    ].take(limit).toList();
  }
}
