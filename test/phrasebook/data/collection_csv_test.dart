import 'dart:convert';

import 'package:flutter_test/flutter_test.dart';
import 'package:mozhi/history/data/phrasebook_csv.dart';
import 'package:mozhi/phrasebook/data/collection_csv.dart';
import 'package:mozhi/phrasebook/data/phrasebook_repository.dart';

void main() {
  final time = DateTime(2026, 10, 22, 9);

  group('CollectionCsv', () {
    test('writes one row per phrase after Anki’s header lines', () {
      final phrases = [
        const PhraseDraft(
          text: 'Hello, friend',
          translation: 'Olá',
          sourceCode: 'en',
          targetCode: 'pt',
          note: 'informal',
        ).toPhrase('p:1', time),
        const PhraseDraft(
          text: 'x',
          translation: 'y',
          sourceCode: 'und',
          targetCode: 'xx-unknown',
        ).toPhrase('p:2', time),
      ];
      expect(
        CollectionCsv.encode(phrases),
        '#separator:Comma\r\n#html:false\r\n'
        '"Hello, friend",Olá,English,Portuguese,2026-10-22,informal\r\n'
        'x,y,,xx-unknown,2026-10-22,\r\n',
      );
      final bytes = CollectionCsv.bytes(phrases);
      expect(bytes.take(3), [0xEF, 0xBB, 0xBF]);
      expect(
        utf8.decode(bytes.skip(3).toList()),
        CollectionCsv.encode(phrases),
      );
      expect(CollectionCsv.mimeType, 'text/csv');
    });

    test('names the file after the collection', () {
      expect(
        CollectionCsv.fileName('Trip to Lisbon'),
        'mozhi-Trip-to-Lisbon.csv',
      );
      expect(CollectionCsv.fileName(' a/b: c? '), 'mozhi-a-b-c.csv');
      expect(CollectionCsv.fileName('...'), 'mozhi-phrasebook.csv');
      expect(
        CollectionCsv.fileName('x' * 100).length,
        'mozhi-.csv'.length + 60,
      );
    });
  });

  group('CsvImportMapping', () {
    final table = PhrasebookCsv.parse(
      'Front,Back,Note\nHello,Olá,greeting\nThanks,,missing\n,Sim,missing\n'
      'Yes,Sim,\n',
    );

    test('suggests the first two columns and a header', () {
      final mapping = CsvImportMapping.suggest(
        table,
        sourceCode: 'en',
        targetCode: 'pt',
      );
      expect(mapping.textColumn, 0);
      expect(mapping.translationColumn, 1);
      expect(mapping.hasHeader, isTrue);
      expect(mapping.isValid, isTrue);
      final drafts = mapping.drafts(table);
      expect(drafts.map((d) => d.text), ['Hello', 'Yes']);
      expect(drafts.first.sourceCode, 'en');
      expect(drafts.first.targetCode, 'pt');
      expect(mapping.copyWith(hasHeader: false).drafts(table), hasLength(3));
    });

    test('maps other columns and languages', () {
      final mapping =
          CsvImportMapping.suggest(
            table,
            sourceCode: 'en',
            targetCode: 'pt',
          ).copyWith(
            textColumn: 2,
            translationColumn: 0,
            sourceCode: 'de',
            targetCode: 'fr',
          );
      final drafts = mapping.drafts(table);
      expect(drafts.map((d) => (d.text, d.translation)), [
        ('greeting', 'Hello'),
        ('missing', 'Thanks'),
      ]);
      expect(drafts.first.sourceCode, 'de');
      expect(mapping.copyWith(translationColumn: 2).isValid, isFalse);
    });

    test('a one-column file maps both to it (invalid)', () {
      final single = PhrasebookCsv.parse('only\none\n');
      final mapping = CsvImportMapping.suggest(
        single,
        sourceCode: 'en',
        targetCode: 'pt',
      );
      expect(mapping.isValid, isFalse);
      expect(mapping.hasHeader, isFalse);
    });

    test('headers', () {
      expect(
        CsvImportMapping.looksLikeHeader(['English', 'Portuguese']),
        isTrue,
      );
      expect(CsvImportMapping.looksLikeHeader(['Text', 'Translation']), isTrue);
      expect(CsvImportMapping.looksLikeHeader(['Hello', 'Olá']), isFalse);
      expect(CsvImportMapping.looksLikeHeader(['Front']), isFalse);
      expect(CsvImportMapping.looksLikeHeader(['', 'Back']), isFalse);
    });
  });
}
