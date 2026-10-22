import 'package:test/test.dart';
import 'package:translation_repository/translation_repository.dart';

import 'pack_helpers.dart';

void main() {
  late DictionaryPackReader reader;

  setUp(() async {
    reader = await DictionaryPackReader.open(
      MemoryDictionaryPackSource(buildTestPack()),
    );
  });

  group('define', () {
    test('merges the entries of a headword', () async {
      final answer = (await reader.define('house', target: 'de'))!;
      expect(answer.language, 'en');
      expect(answer.attribution, reader.header.attribution);
      expect(answer.inflectedForm, isNull);
      expect(answer.otherLemmas, isEmpty);
      expect(
        answer.entry,
        const DictionaryEntry(
          word: 'house',
          pronunciation: 'haʊs',
          partsOfSpeech: ['noun', 'verb'],
          senses: [
            DictionarySense(
              definition: 'A structure serving as an abode.',
              partOfSpeech: 'noun',
              translations: ['Haus'],
              usage: 'countable',
            ),
            DictionarySense(
              definition: 'A dynasty.',
              partOfSpeech: 'noun',
              translations: ['Dynastie'],
            ),
            DictionarySense(
              definition: 'To keep within a structure.',
              partOfSpeech: 'verb',
            ),
          ],
          examples: [
            DictionaryExample(source: 'This is my house.'),
            DictionaryExample(
              source: 'the House of Windsor',
              translation: 'das Haus',
            ),
          ],
          synonyms: ['home', 'dwelling', 'shelter'],
          etymology: 'From Old English hūs.',
          relatedWords: ['household'],
        ),
      );
    });

    test('puts translations of the whole entry on its first sense', () async {
      final answer = (await reader.define('house', target: 'zh-CN'))!;
      expect(
        [for (final sense in answer.entry.senses) sense.translations],
        [
          ['房子'],
          <String>[],
          <String>[],
        ],
      );
      final none = (await reader.define('house', target: 'fr'))!;
      expect(none.entry.senses.first.translations, isEmpty);
      final noTarget = (await reader.define('house'))!;
      expect(noTarget.entry.senses.first.translations, isEmpty);
    });

    test('prefers the spelling that was looked up', () async {
      expect((await reader.define('Polish'))!.entry.partsOfSpeech, ['adj']);
      expect((await reader.define('polish'))!.entry.partsOfSpeech, ['verb']);
      // Neither written like this: both, merged under the first.
      final both = (await reader.define('POLISH'))!;
      expect(both.entry.word, 'Polish');
      expect(both.entry.partsOfSpeech, ['adj', 'verb']);
      expect((await reader.define('CAFE'))!.entry.word, 'café');
    });

    test('answers an inflected form with its lemma', () async {
      final gone = (await reader.define(' gone '))!;
      expect(gone.entry.word, 'go');
      expect(gone.inflectedForm, 'gone');
      expect(gone.entry.senses.single.definition, 'To move.');
      final houses = (await reader.define('houses'))!;
      expect(houses.entry.word, 'house');
      expect(houses.entry.partsOfSpeech, ['noun', 'verb']);
      expect(houses.inflectedForm, 'houses');
    });

    test('lists other lemmas of a headword', () async {
      final went = (await reader.define('went'))!;
      expect(went.entry.word, 'went');
      expect(went.entry.senses.single.usage, 'archaic');
      expect(went.otherLemmas, ['go']);
      final left = (await reader.define('left'))!;
      expect(left.entry.partsOfSpeech, ['adj']);
      expect(left.otherLemmas, ['leave']);
    });

    test('answers a form whose lemma is missing with its own entry', () async {
      final mice = (await reader.define('mice'))!;
      expect(mice.entry.word, 'mice');
      expect(mice.entry.senses.single.definition, 'plural of mouse');
      expect(mice.inflectedForm, isNull);
    });

    test('is null for unknown words', () async {
      expect(await reader.define('zebra'), isNull);
      expect(await reader.define(''), isNull);
    });
  });

  group('mergePackEntries', () {
    test('caps senses, examples, words and translations', () {
      final entry = DictionaryPackEntry(
        word: 'big',
        senses: [
          for (var i = 0; i < 30; i++)
            DictionaryPackSense(
              gloss: i == 3 ? '  ' : 'sense $i',
              examples: [
                DictionaryPackExample('example $i'),
                const DictionaryPackExample(' '),
              ],
            ),
        ],
        synonyms: [for (var i = 0; i < 20; i++) 'synonym $i', 'big', ''],
        relatedWords: [for (var i = 0; i < 20; i++) 'related $i'],
        translations: {
          'de': [
            for (var i = 0; i < 10; i++)
              DictionaryPackTranslation('wort $i', 0),
            const DictionaryPackTranslation('wort 1', 0),
            const DictionaryPackTranslation(' ', 0),
          ],
        },
      );
      final merged = mergePackEntries([entry], target: 'de');
      expect(merged.senses, hasLength(DictionaryPackAnswers.maxSenses));
      expect(
        merged.senses.map((sense) => sense.definition),
        isNot(contains('  ')),
      );
      expect(merged.examples, hasLength(DictionaryPackAnswers.maxExamples));
      expect(merged.synonyms, hasLength(DictionaryPackAnswers.maxWords));
      expect(merged.synonyms, isNot(contains('big')));
      expect(merged.relatedWords, hasLength(DictionaryPackAnswers.maxWords));
      expect(
        merged.senses.first.translations,
        hasLength(DictionaryPackAnswers.maxTranslations),
      );
      expect(merged.pronunciation, '');
      expect(merged.etymology, '');
    });

    test('needs entries', () {
      expect(() => mergePackEntries(const []), throwsArgumentError);
    });
  });
}
