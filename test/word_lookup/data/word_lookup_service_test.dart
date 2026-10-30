import 'package:flutter_test/flutter_test.dart';
import 'package:mocktail/mocktail.dart';
import 'package:mozhi/usage/models/usage_stats.dart';
import 'package:mozhi/word_lookup/data/word_lookup_service.dart';
import 'package:mozhi/word_lookup/data/word_segmenter.dart';
import 'package:translation_repository/translation_repository.dart';

import '../helpers.dart';

void main() {
  setUpAll(() {
    registerFallbackValue(english);
    registerFallbackValue(aiEngine);
    registerFallbackValue(DictionaryVerbosity.concise);
  });

  group('hasDictionaryFor', () {
    test('a dictionary of the language, or of its primary language', () async {
      final service = WordLookupService(
        offlineDictionary: FakeOfflineDictionary(languages: ['es', 'pt']),
      );
      expect(await service.hasDictionaryFor(spanish), isTrue);
      expect(
        await service.hasDictionaryFor(
          const Language(code: 'pt-BR', name: 'Portuguese (Brazil)'),
        ),
        isTrue,
      );
      expect(await service.hasDictionaryFor(english), isFalse);
    });

    test('any dictionary for detected and custom languages', () async {
      final service = WordLookupService(
        offlineDictionary: FakeOfflineDictionary(),
      );
      expect(await service.hasDictionaryFor(Language.auto), isTrue);
      expect(
        await service.hasDictionaryFor(const Language.custom('Pirate')),
        isTrue,
      );
      final none = WordLookupService(
        offlineDictionary: FakeOfflineDictionary(languages: []),
      );
      expect(await none.hasDictionaryFor(Language.auto), isFalse);
    });

    test('false without dictionaries or when they fail', () async {
      expect(await WordLookupService().hasDictionaryFor(spanish), isFalse);
      final failing = FakeOfflineDictionary()..error = StateError('broken');
      expect(
        await WordLookupService(offlineDictionary: failing)
            .hasDictionaryFor(spanish),
        isFalse,
      );
    });
  });

  group('lookUpOffline', () {
    test('asks the dictionary of the language, with translations', () async {
      final dictionary = FakeOfflineDictionary();
      final service = WordLookupService(offlineDictionary: dictionary);
      final answer = await service.lookUpOffline(
        'gato',
        language: spanish,
        into: english,
      );
      expect(answer, gatoAnswer);
      expect(dictionary.lookUps.single, (
        word: 'gato',
        language: 'es',
        target: 'en',
      ));
    });

    test('every dictionary for a detected language', () async {
      final dictionary = FakeOfflineDictionary();
      await WordLookupService(offlineDictionary: dictionary)
          .lookUpOffline('gato', language: Language.auto);
      expect(dictionary.lookUps.single, (
        word: 'gato',
        language: null,
        target: null,
      ));
    });

    test('a word after an elided article without it', () async {
      final dictionary = FakeOfflineDictionary(
        languages: ['fr'],
        answers: {},
        words: {'homme'},
      );
      final service = WordLookupService(offlineDictionary: dictionary);
      const french = Language(code: 'fr', name: 'French');
      final answer = await service.lookUpOffline('l’homme', language: french);
      expect(answer?.entry.word, 'homme');
      expect(
        [for (final call in dictionary.lookUps) call.word],
        ['l’homme', 'homme'],
      );
      expect(await service.lookUpOffline("don't", language: french), isNull);
    });

    test('nothing for a blank word or without dictionaries', () async {
      final dictionary = FakeOfflineDictionary();
      expect(
        await WordLookupService(offlineDictionary: dictionary)
            .lookUpOffline('  ', language: spanish),
        isNull,
      );
      expect(dictionary.lookUps, isEmpty);
      expect(
        await WordLookupService().lookUpOffline('gato', language: spanish),
        isNull,
      );
    });

    test('throws what the dictionary throws', () async {
      final dictionary = FakeOfflineDictionary()..error = StateError('broken');
      expect(
        WordLookupService(offlineDictionary: dictionary)
            .lookUpOffline('gato', language: spanish),
        throwsStateError,
      );
    });
  });

  group('lookUpOnline', () {
    late MockTranslationRepository repository;
    late MockUsageTracker usage;

    setUp(() {
      repository = MockTranslationRepository();
      usage = MockUsageTracker();
      when(
        () => repository.lookUp(
          any(),
          any(),
          source: any(named: 'source'),
          target: any(named: 'target'),
          context: any(named: 'context'),
          uiLanguage: any(named: 'uiLanguage'),
          verbosity: any(named: 'verbosity'),
        ),
      ).thenAnswer((_) async => aiGatoEntry);
      when(
        () => usage.recordText(
          any(),
          input: any(named: 'input'),
          output: any(named: 'output'),
        ),
      ).thenAnswer((_) async => UsageStats.zero);
    });

    test('asks the engine with the sentence as context', () async {
      final service = WordLookupService(
        repository: repository,
        usageTracker: usage,
      );
      final entry = await service.lookUpOnline(
        aiEngine,
        'gato',
        language: spanish,
        into: english,
        sentence: 'El gato duerme.',
        uiLanguage: 'German',
      );
      expect(entry, aiGatoEntry);
      verify(
        () => repository.lookUp(
          aiEngine,
          'gato',
          source: spanish,
          target: english,
          context: 'El gato duerme.',
          uiLanguage: 'German',
          verbosity: DictionaryVerbosity.concise,
        ),
      ).called(1);
      verify(
        () => usage.recordText(
          'openai',
          input: 'gato\nEl gato duerme.',
          output: any(named: 'output'),
        ),
      ).called(1);
    });

    test('a custom language goes as a detected one', () async {
      await WordLookupService(repository: repository).lookUpOnline(
        aiEngine,
        'arr',
        language: const Language.custom('Pirate'),
        into: english,
      );
      verify(
        () => repository.lookUp(
          aiEngine,
          'arr',
          source: Language.auto,
          target: english,
          verbosity: DictionaryVerbosity.concise,
        ),
      ).called(1);
    });

    test('counts nothing for engines without a provider', () async {
      const local = TranslationEngine(
        id: 'local',
        kind: EngineKind.ai,
        name: 'Local',
        isLocal: true,
      );
      await WordLookupService(
        repository: repository,
        usageTracker: usage,
      ).lookUpOnline(local, 'gato', language: spanish, into: english);
      verifyNever(
        () => usage.recordText(
          any(),
          input: any(named: 'input'),
          output: any(named: 'output'),
        ),
      );
    });

    test('a failing usage tracker does not fail the look-up', () async {
      when(
        () => usage.recordText(
          any(),
          input: any(named: 'input'),
          output: any(named: 'output'),
        ),
      ).thenThrow(StateError('full'));
      final entry = await WordLookupService(
        repository: repository,
        usageTracker: usage,
      ).lookUpOnline(aiEngine, 'gato', language: spanish, into: english);
      expect(entry, aiGatoEntry);
    });

    test('passes on what the privacy settings throw', () async {
      when(
        () => repository.lookUp(
          any(),
          any(),
          source: any(named: 'source'),
          target: any(named: 'target'),
          context: any(named: 'context'),
          uiLanguage: any(named: 'uiLanguage'),
          verbosity: any(named: 'verbosity'),
        ),
      ).thenThrow(
        const ConsentRequiredException(
          kind: ConsentKind.cloudProvider,
          destination: CloudProviderDestination('OpenAI'),
          engineId: 'openai:gpt',
        ),
      );
      expect(
        WordLookupService(repository: repository)
            .lookUpOnline(aiEngine, 'gato', language: spanish, into: english),
        throwsA(isA<ConsentRequiredException>()),
      );
    });

    test('fails without a repository', () {
      expect(
        WordLookupService().lookUpOnline(
          aiEngine,
          'gato',
          language: spanish,
          into: english,
        ),
        throwsStateError,
      );
    });
  });

  group('word index', () {
    test('null without dictionaries', () {
      expect(WordLookupService().indexFor(chinese), isNull);
    });

    test("the dictionary's words and prefixes", () async {
      final dictionary = FakeOfflineDictionary(
        languages: ['zh'],
        answers: {},
        words: {'北京', '北京大学'},
      );
      final index = WordLookupService(offlineDictionary: dictionary)
          .indexFor(chinese)!;
      expect(await index.contains('北京'), isTrue);
      expect(await index.contains('东京'), isFalse);
      expect(await index.hasPrefix('北京大'), isTrue);
      expect(await index.hasPrefix('东'), isFalse);
      expect(dictionary.lookUps.first.language, 'zh');
    });

    test('a failing dictionary has no words', () async {
      final dictionary = FakeOfflineDictionary()..error = StateError('broken');
      final index = WordLookupService(offlineDictionary: dictionary)
          .indexFor(chinese)!;
      expect(await index.contains('北京'), isFalse);
      expect(await index.hasPrefix('北'), isFalse);
    });
  });

  group('wordAt', () {
    const text = '我喜欢北京大学';

    test('the longest word of the installed dictionary', () async {
      final service = WordLookupService(
        offlineDictionary: FakeOfflineDictionary(
          languages: ['zh'],
          answers: {},
          words: {'北京', '北京大学'},
        ),
      );
      expect(
        await service.wordAt(text, text.indexOf('京'), language: chinese),
        const TextWord(3, 7, '北京大学'),
      );
    });

    test('one character without a dictionary of the language', () async {
      final dictionary = FakeOfflineDictionary(
        answers: {},
        words: {'北京', '北京大学'},
      );
      final service = WordLookupService(offlineDictionary: dictionary);
      expect(
        (await service.wordAt(
          text,
          text.indexOf('京'),
          language: chinese,
        ))?.text,
        '京',
      );
      expect(dictionary.lookUps, isEmpty);
    });

    test('words with spaces need no dictionary', () async {
      final dictionary = FakeOfflineDictionary();
      final service = WordLookupService(offlineDictionary: dictionary);
      expect(
        (await service.wordAt('El gato duerme', 4, language: spanish))?.text,
        'gato',
      );
      expect(await service.wordAt('El  gato', 3, language: spanish), isNull);
      expect(dictionary.lookUps, isEmpty);
    });
  });
}
