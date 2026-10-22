import 'dart:convert';

import 'package:flutter_test/flutter_test.dart';
import 'package:mozhi/phrasebook/data/phrasebook_repository.dart';
import 'package:mozhi/practice/data/anki_export.dart';
import 'package:mozhi/practice/data/anki_notes.dart';

import '../helpers.dart';

void main() {
  group(AnkiExport, () {
    test("writes Anki's header and one tab-separated line per note", () {
      final text = AnkiExport.encode(const [
        AnkiNote(
          front: 'Onde fica a estação?',
          back: 'Where is the station?',
          tags: ['Mozhi::Trip to Lisbon', 'en-pt'],
        ),
        AnkiNote(front: 'Obrigado', back: 'Thank you'),
      ]);
      expect(
        text,
        '#separator:tab\n'
        '#html:false\n'
        '#tags column:3\n'
        'Onde fica a estação?\tWhere is the station?\t'
        'Mozhi::Trip_to_Lisbon en-pt\n'
        'Obrigado\tThank you\t\n',
      );
      expect(
        utf8.decode(AnkiExport.bytes(const [AnkiNote(front: 'é', back: 'e')])),
        endsWith('é\te\t\n'),
      );
    });

    test('quotes fields with tabs, line breaks, quotes or a leading #', () {
      expect(AnkiExport.field('plain'), 'plain');
      expect(AnkiExport.field('a\tb'), '"a\tb"');
      expect(AnkiExport.field('line\nbreak'), '"line\nbreak"');
      expect(AnkiExport.field('say "hi"'), '"say ""hi"""');
      expect(AnkiExport.field('#1'), '"#1"');
    });

    test('makes tags', () {
      expect(
        AnkiExport.tag('  Trip to  Lisbon "2026" '),
        'Trip_to_Lisbon_2026',
      );
      expect(AnkiExport.collectionTag('Work Japanese'), 'Mozhi::Work_Japanese');
      expect(AnkiExport.pairTag('en', 'pt-BR'), 'en-pt-BR');
      // Duplicate and empty tags are dropped.
      expect(
        AnkiExport.encode(const [
          AnkiNote(front: 'a', back: 'b', tags: ['x', 'x', ' ']),
        ]),
        endsWith('a\tb\tx\n'),
      );
    });

    test('notes are equal by value', () {
      expect(
        const AnkiNote(front: 'a', back: 'b', tags: ['t']),
        const AnkiNote(front: 'a', back: 'b', tags: ['t']),
      );
    });

    test('names the file', () {
      expect(AnkiExport.fileName(), 'mozhi-anki.txt');
      expect(AnkiExport.fileName('  '), 'mozhi-anki.txt');
      expect(
        AnkiExport.fileName('Trip to Lisbon!'),
        'mozhi-anki-trip-to-lisbon.txt',
      );
      expect(AnkiExport.fileName('日本語'), 'mozhi-anki-日本語.txt');
      expect(AnkiExport.fileName('a' * 60), 'mozhi-anki-${'a' * 40}.txt');
    });
  });

  group('ankiNotesOf', () {
    test('a note per phrase with the learned side in front', () async {
      final fixture = PracticeFixture(favorites: [favorite('1')]);
      final trip = await fixture.collection('Trip', ['Hello']);
      final work = await fixture.phrasebook.createCollection('Work');
      final hello = (await fixture.phrasebook.phrases(collectionId: trip.id))
          .single;
      await fixture.phrasebook.copyPhrase(hello.id, work.id);
      await fixture.phrasebook.updateNote(hello.id, 'Say it with a smile');
      await fixture.phrasebook.addPhrase(
        const PhraseDraft(
          text: 'Saída',
          translation: 'Exit',
          sourceCode: 'pt',
          targetCode: 'en',
        ),
        trip.id,
      );
      String name(PhraseCollection collection) =>
          collection.isFavorites ? 'Favorites' : collection.name;

      final all = await ankiNotesOf(
        fixture.phrasebook,
        appLanguage: 'en',
        nameOf: name,
      );
      expect(all, hasLength(3));
      final note = all.firstWhere((note) => note.back.startsWith('Hello'));
      expect(note.front, 'Hello (pt)');
      expect(note.back, 'Hello\nSay it with a smile');
      expect(note.tags, ['Mozhi::Work', 'Mozhi::Trip', 'en-pt']);
      final exit = all.firstWhere((note) => note.front == 'Saída');
      expect(exit.back, 'Exit');
      expect(exit.tags, ['Mozhi::Trip', 'pt-en']);
      expect(all.firstWhere((note) => note.front == 'tradução 1').tags, [
        'Mozhi::Favorites',
        'en-pt',
      ]);

      final one = await ankiNotesOf(
        fixture.phrasebook,
        appLanguage: 'en',
        nameOf: name,
        collectionId: work.id,
      );
      expect(one.single.tags, ['Mozhi::Work', 'en-pt']);
    });
  });
}
