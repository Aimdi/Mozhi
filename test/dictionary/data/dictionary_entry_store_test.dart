import 'package:flutter_test/flutter_test.dart';
import 'package:mozhi/dictionary/data/dictionary_entry_store.dart';
import 'package:translation_repository/translation_repository.dart';

import '../helpers/dictionary_helpers.dart';

void main() {
  group('encodeDictionaryEntry / decodeDictionaryEntry', () {
    test('round-trip a full entry', () {
      const entry = DictionaryEntry(
        word: 'gato',
        pronunciation: 'ˈɡato',
        partsOfSpeech: ['noun'],
        senses: [
          DictionarySense(
            definition: 'A small domesticated feline.',
            partOfSpeech: 'noun',
            translations: ['cat', 'tomcat'],
            usage: 'common',
          ),
          DictionarySense(definition: 'A car jack.'),
        ],
        examples: [
          DictionaryExample(source: 'El gato duerme.', translation: 'x'),
          DictionaryExample(source: 'Un gato.'),
        ],
        synonyms: ['minino'],
        etymology: 'From Late Latin cattus.',
        notes: 'Also a car jack.',
        relatedWords: ['gatito'],
        didYouMean: 'gata',
      );
      expect(decodeDictionaryEntry(encodeDictionaryEntry(entry)), entry);
      expect(
        decodeDictionaryEntry(encodeDictionaryEntry(gatoEntry)),
        gatoEntry,
      );
    });

    test('a minimal entry keeps only what it has', () {
      const entry = DictionaryEntry(
        word: 'x',
        senses: [DictionarySense(definition: 'y')],
      );
      expect(encodeDictionaryEntry(entry), contains('"word":"x"'));
      expect(encodeDictionaryEntry(entry), isNot(contains('examples')));
      expect(decodeDictionaryEntry(encodeDictionaryEntry(entry)), entry);
    });

    test('an entry too large to keep is not encoded', () {
      final entry = DictionaryEntry(
        word: 'big',
        notes: 'n' * (maxStoredDictionaryEntryLength + 1),
      );
      expect(encodeDictionaryEntry(entry), isNull);
    });

    test('nothing for missing, blank, broken or empty JSON', () {
      expect(decodeDictionaryEntry(null), isNull);
      expect(decodeDictionaryEntry('  '), isNull);
      expect(decodeDictionaryEntry('{not json'), isNull);
      expect(decodeDictionaryEntry('{}'), isNull);
    });
  });

  test('firstDictionaryTranslation skips senses without one', () {
    expect(
      firstDictionaryTranslation(
        const DictionaryEntry(
          word: 'gato',
          senses: [
            DictionarySense(definition: 'a', translations: [' ']),
            DictionarySense(definition: 'b', translations: [' cat ', 'puss']),
          ],
        ),
      ),
      'cat',
    );
    expect(
      firstDictionaryTranslation(
        const DictionaryEntry(
          word: 'gato',
          senses: [DictionarySense(definition: 'a')],
        ),
      ),
      isNull,
    );
  });

  group('DictionaryEntryCache', () {
    DictionaryEntry entry(String word) => DictionaryEntry(
      word: word,
      senses: [DictionarySense(definition: word)],
    );

    DictionaryEntry? get(
      DictionaryEntryCache cache,
      String word, {
      Language target = english,
      DictionaryVerbosity verbosity = DictionaryVerbosity.standard,
      String engineId = 'ai:claude',
      String context = '',
    }) => cache.get(
      word,
      source: spanish,
      target: target,
      verbosity: verbosity,
      engineId: engineId,
      context: context,
    );

    void put(DictionaryEntryCache cache, String word) => cache.put(
      word,
      entry(word),
      source: spanish,
      target: english,
      verbosity: DictionaryVerbosity.standard,
      engineId: 'ai:claude',
    );

    test('keeps entries per word, languages, level, engine and context', () {
      final cache = DictionaryEntryCache();
      put(cache, 'gato');
      expect(get(cache, ' gato '), entry('gato'));
      expect(get(cache, 'gato', target: french), isNull);
      expect(
        get(cache, 'gato', verbosity: DictionaryVerbosity.concise),
        isNull,
      );
      expect(get(cache, 'gato', engineId: 'ai:other'), isNull);
      expect(get(cache, 'gato', context: 'El gato.'), isNull);
    });

    test('drops the least recently used beyond its capacity', () {
      final cache = DictionaryEntryCache(capacity: 2);
      put(cache, 'a');
      put(cache, 'b');
      expect(get(cache, 'a'), isNotNull);
      put(cache, 'c');
      expect(cache.length, 2);
      expect(get(cache, 'b'), isNull);
      expect(get(cache, 'a'), isNotNull);
      expect(get(cache, 'c'), isNotNull);
      put(cache, 'c');
      expect(cache.length, 2);
      cache.clear();
      expect(cache.length, 0);
    });

    test('one per repository', () {
      final repository = MockTranslationRepository();
      expect(
        DictionaryEntryCache.of(repository),
        same(DictionaryEntryCache.of(repository)),
      );
      expect(
        DictionaryEntryCache.of(repository),
        isNot(same(DictionaryEntryCache.of(MockTranslationRepository()))),
      );
    });
  });
}
