import 'dart:io';

import 'package:test/test.dart';
import 'package:translation_repository/translation_repository.dart';

/// `test/fixtures/dictionary_packs/en.mzd` was built by
/// `tool/dictionary_packs.py` from `tool/dictionary_packs_fixtures/
/// kaikki_en.jsonl` (`python3 tool/dictionary_packs_test.py --update`):
/// the Dart reader must read exactly what the Python builder writes
/// (compressed with zlib, folded with Python's Unicode tables).
void main() {
  late DictionaryPackReader reader;

  setUp(() async {
    final bytes = File('test/fixtures/dictionary_packs/en.mzd')
        .readAsBytesSync();
    reader = await DictionaryPackReader.open(MemoryDictionaryPackSource(bytes));
  });

  tearDown(() => reader.close());

  test('reads the header the tool wrote', () async {
    final header = reader.header;
    expect(header.language, 'en');
    expect(header.glossLanguage, 'en');
    expect(header.name, 'English');
    expect(header.snapshot, '2026-10-01');
    expect(header.extractor, 'wiktextract (kaikki.org)');
    expect(header.targets, ['de', 'es', 'fr', 'it', 'no', 'zh']);
    expect(header.entryCount, 9);
    expect(header.keyCount, 19);
    expect(header.attribution.license, 'CC BY-SA 4.0');
    expect(
      header.attribution.licenseUrl,
      'https://creativecommons.org/licenses/by-sa/4.0/',
    );
    expect(header.attribution.text, contains('Wiktionary contributors'));
    expect(await reader.verify(), isTrue);
  });

  test('finds headwords and forms like the tool', () async {
    final went = await reader.lookUp('went');
    expect(
      [for (final hit in went) (hit.entry.word, hit.viaForm)],
      [('went', false), ('go', true)],
    );
    expect(await reader.suggest('ho'), [
      'house',
      'housed',
      'houses',
      'housing',
    ]);
    expect(await reader.suggest('NA'), ['naïve', 'naïver']);
  });

  test('answers with merged entries', () async {
    final house = (await reader.define('House', target: 'de'))!;
    expect(house.language, 'en');
    expect(house.inflectedForm, isNull);
    final entry = house.entry;
    expect(entry.word, 'house');
    expect(entry.pronunciation, 'haʊs');
    expect(entry.partsOfSpeech, ['noun', 'verb']);
    expect(
      [for (final sense in entry.senses) sense.translations],
      [
        ['Haus'],
        ['Dynastie'],
        <String>[],
        ['unterbringen'],
      ],
    );
    expect(entry.senses[2].usage, 'countable, informal');
    expect(entry.senses[3].partOfSpeech, 'verb');
    expect(entry.synonyms, ['domicile', 'home', 'dwelling']);
    expect(entry.relatedWords, ['household', 'housekeeper', 'lighthouse']);
    expect(
      entry.examples.first.source,
      "This is my house and my family's ancestral home.",
    );
    expect(entry.etymology, startsWith('From Middle English hous'));
    expect(
      (await reader.define(
        'house',
        target: 'zh-TW',
      ))!.entry.senses.first.translations,
      ['房子'],
    );
  });

  test('folds accents and case with the tool’s table', () async {
    for (final query in ['cafe', 'CAFÉ', 'Café']) {
      final answer = (await reader.define(query, target: 'fr'))!;
      expect(answer.entry.word, 'café', reason: query);
      expect(answer.entry.senses.single.translations, ['café']);
      expect(answer.entry.pronunciation, 'ˈkæfeɪ');
    }
    expect((await reader.define('NAIVE'))!.entry.word, 'naïve');
    expect((await reader.define('Polish'))!.entry.partsOfSpeech, ['adj']);
    expect((await reader.define('polish'))!.entry.partsOfSpeech, ['verb']);
  });

  test('answers inflected forms with their lemma', () async {
    final gone = (await reader.define('gone'))!;
    expect(gone.entry.word, 'go');
    expect(gone.inflectedForm, 'gone');
    final went = (await reader.define('went'))!;
    expect(went.entry.word, 'went');
    expect(went.inflectedForm, isNull);
    expect(went.otherLemmas, ['go']);
    expect(
      (await reader.define(
        'bank',
        target: 'no',
      ))!.entry.senses.first.translations,
      ['bank'],
    );
    expect(await reader.define('kerfuffle'), isNull);
  });
}
