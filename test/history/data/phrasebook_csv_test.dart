import 'dart:convert';

import 'package:flutter_test/flutter_test.dart';
import 'package:mozhi/history/data/phrasebook_csv.dart';
import 'package:mozhi/history/models/history_entry.dart';
import 'package:translation_repository/translation_repository.dart';

HistoryEntry _entry(
  String text,
  String translation, {
  Language source = const Language(code: 'en', name: 'English'),
  Language target = const Language(code: 'fr', name: 'French'),
  String? detected,
  HistoryEntryKind kind = HistoryEntryKind.translation,
}) => HistoryEntry(
  id: text,
  text: text,
  translation: translation,
  source: source,
  target: target,
  engineId: 'mozhi:google',
  engineName: 'Google',
  createdAt: DateTime(2026, 3, 7, 23, 59),
  detectedSource: detected,
  isFavorite: true,
  kind: kind,
);

void main() {
  group(PhrasebookCsv, () {
    test('starts with the Anki header and one CRLF row per entry', () {
      final csv = PhrasebookCsv.encode([
        _entry('Good morning', 'Bonjour'),
        _entry(
          'gato',
          'noun · cat',
          source: const Language(code: 'es', name: 'Spanish'),
          target: const Language(code: 'en', name: 'English'),
          kind: HistoryEntryKind.dictionary,
        ),
      ]);
      expect(
        csv,
        '#separator:Comma\r\n'
        '#html:false\r\n'
        'Good morning,Bonjour,English,French,2026-03-07\r\n'
        'gato,noun · cat,Spanish,English,2026-03-07\r\n',
      );
    });

    test('names the detected language as the source', () {
      final csv = PhrasebookCsv.encode([
        _entry('Hallo', 'Hello', source: Language.auto, detected: 'de'),
      ]);
      expect(csv, endsWith('Hallo,Hello,German,French,2026-03-07\r\n'));
    });

    test('quotes fields as RFC 4180 says', () {
      expect(PhrasebookCsv.field('plain'), 'plain');
      expect(PhrasebookCsv.field('a, b'), '"a, b"');
      expect(PhrasebookCsv.field('say "hi"'), '"say ""hi"""');
      expect(PhrasebookCsv.field('two\nlines'), '"two\nlines"');
      expect(PhrasebookCsv.field('cr\rlf'), '"cr\rlf"');
      expect(PhrasebookCsv.field(' padded '), '" padded "');
      // Never taken for one of Anki's header lines.
      expect(PhrasebookCsv.field('#tag'), '"#tag"');
      expect(PhrasebookCsv.field(''), '');
    });

    test('is UTF-8 with a byte order mark', () {
      final bytes = PhrasebookCsv.bytes([_entry('Thank you', 'Merci ✓')]);
      expect(bytes.take(3), [0xEF, 0xBB, 0xBF]);
      expect(
        utf8.decode(bytes.sublist(3)),
        PhrasebookCsv.encode([_entry('Thank you', 'Merci ✓')]),
      );
    });

    test('dates are local and zero-padded', () {
      expect(PhrasebookCsv.date(DateTime(987, 1, 2)), '0987-01-02');
    });
  });
}
