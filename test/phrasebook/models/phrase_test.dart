import 'package:flutter_test/flutter_test.dart';
import 'package:mozhi/history/models/history_entry.dart';
import 'package:mozhi/phrasebook/models/phrase.dart';
import 'package:mozhi/phrasebook/models/phrase_collection.dart';
import 'package:mozhi/phrasebook/models/phrase_draft.dart';
import 'package:translation_repository/translation_repository.dart';

final DateTime _time = DateTime.utc(2026, 10, 22, 9).toLocal();

Phrase _phrase({String id = 'p:1', String note = ''}) => Phrase(
  id: id,
  text: 'Hello',
  translation: 'Olá',
  sourceCode: 'en',
  targetCode: 'pt',
  createdAt: _time,
  updatedAt: _time.add(const Duration(minutes: 1)),
  note: note,
  origin: PhraseOrigin.history,
  pronunciation: 'oh-LAH',
  topic: 'Basics',
);

void main() {
  group('Phrase', () {
    test('round-trips through JSON', () {
      final phrase = _phrase(note: 'Say it with a smile');
      final parsed = Phrase.fromJson(phrase.toJson());
      expect(parsed, phrase);
      expect(parsed.createdAt.isAtSameMomentAs(phrase.createdAt), isTrue);
      expect(parsed.note, 'Say it with a smile');
      expect(parsed.origin, PhraseOrigin.history);
      expect(parsed.pronunciation, 'oh-LAH');
      expect(parsed.topic, 'Basics');
    });

    test('leaves empty optional fields out of its JSON', () {
      final json = Phrase(
        id: 'p:1',
        text: 'a',
        translation: 'b',
        sourceCode: 'en',
        targetCode: 'fr',
        createdAt: _time,
        updatedAt: _time,
      ).toJson();
      expect(json.containsKey('note'), isFalse);
      expect(json.containsKey('pronunciation'), isFalse);
      expect(json.containsKey('topic'), isFalse);
      expect(json['origin'], 'manual');
      expect(json['createdAt'], '2026-10-22T09:00:00.000Z');
    });

    test(
      'reads millisecond times, a missing updatedAt and unknown origins',
      () {
        final phrase = Phrase.fromJson({
          'id': 'p:2',
          'text': 'a',
          'translation': 'b',
          'sourceCode': 'en',
          'targetCode': 'fr',
          'createdAt': _time.millisecondsSinceEpoch,
          'origin': 'somewhere',
          'note': 3,
        });
        expect(phrase.createdAt.isAtSameMomentAs(_time), isTrue);
        expect(phrase.updatedAt, phrase.createdAt);
        expect(phrase.origin, PhraseOrigin.manual);
        expect(phrase.note, '');
      },
    );

    test('rejects invalid JSON', () {
      expect(
        () => Phrase.fromJson(const {'id': 'p:1', 'text': 'a'}),
        throwsFormatException,
      );
      expect(
        () => Phrase.fromJson(const {
          'id': '',
          'text': 'a',
          'translation': 'b',
          'sourceCode': 'en',
          'targetCode': 'fr',
          'createdAt': '2026-10-22T09:00:00Z',
        }),
        throwsFormatException,
      );
      expect(
        () => Phrase.fromJson(const {
          'id': 'p:1',
          'text': 'a',
          'translation': 'b',
          'sourceCode': 'en',
          'targetCode': 'fr',
          'createdAt': 'yesterday',
        }),
        throwsFormatException,
      );
    });

    test('ids say where a phrase lives', () {
      expect(Phrase.favoriteId('42'), 'h:42');
      expect(Phrase.historyIdOf('h:42'), '42');
      expect(Phrase.historyIdOf('p:42'), isNull);
      expect(Phrase.starterId('pt', 'abc'), 's:pt:abc');
      expect(Phrase.starterPackOf('s:pt:abc'), 'pt');
      expect(Phrase.starterPackOf('s:pt'), isNull);
      expect(Phrase.starterPackOf('p:1'), isNull);
      expect(_phrase(id: 'h:1').isFavorite, isTrue);
      expect(_phrase(id: 's:pt:1').isStarter, isTrue);
      expect(_phrase().isStored, isTrue);
      expect(_phrase(id: 'h:1').isStored, isFalse);
    });

    test('contentKey ignores surrounding spaces, not the languages', () {
      final a = _phrase();
      final b = a.copyWith(text: ' Hello ', translation: 'Olá ');
      expect(a.contentKey, b.contentKey);
      expect(a.contentKey, isNot(a.copyWith(targetCode: 'es').contentKey));
    });

    test('parseTime', () {
      expect(Phrase.parseTime(null), isNull);
      expect(Phrase.parseTime('nope'), isNull);
      expect(Phrase.parseTime('2026-10-22T09:00:00Z')!.isUtc, isFalse);
    });
  });

  group('PhraseCollection', () {
    PhraseCollection collection({bool starter = false, String id = 'c:1'}) =>
        PhraseCollection(
          id: id,
          name: 'Trip to Lisbon',
          sourceCode: 'en',
          targetCode: 'pt',
          phraseIds: const ['p:1', 'p:2'],
          createdAt: _time,
          updatedAt: _time,
          starter: starter,
        );

    test('round-trips through JSON', () {
      final original = collection(starter: true);
      final parsed = PhraseCollection.fromJson(original.toJson());
      expect(parsed, original);
      expect(parsed.length, 2);
    });

    test('drops duplicate and invalid phrase ids, and empty codes', () {
      final parsed = PhraseCollection.fromJson(const {
        'id': 'c:1',
        'name': 'x',
        'phraseIds': ['p:1', 'p:1', '', 3, 'p:2'],
        'sourceCode': '',
        'createdAt': '2026-10-22T09:00:00Z',
      });
      expect(parsed.phraseIds, ['p:1', 'p:2']);
      expect(parsed.sourceCode, isNull);
      expect(parsed.updatedAt, parsed.createdAt);
      expect(parsed.starter, isFalse);
    });

    test('rejects invalid JSON', () {
      expect(
        () => PhraseCollection.fromJson(const {'id': 'c:1', 'name': 'x'}),
        throwsFormatException,
      );
      expect(
        () => PhraseCollection.fromJson(const {
          'id': 'c:1',
          'name': 'x',
          'phraseIds': <String>[],
        }),
        throwsFormatException,
      );
    });

    test('knows the built-in collections', () {
      expect(collection(id: PhraseCollection.favoritesId).isFavorites, isTrue);
      expect(collection(id: PhraseCollection.favoritesId).isEditable, isFalse);
      expect(collection(starter: true).isEditable, isFalse);
      expect(collection().isEditable, isTrue);
      expect(PhraseCollection.starterId('pt'), 'starter:pt');
      expect(PhraseCollection.starterPackOf('starter:pt'), 'pt');
      expect(PhraseCollection.starterPackOf('c:1'), isNull);
    });

    test('copyWith', () {
      final changed = collection().copyWith(
        name: 'Porto',
        sourceCode: () => null,
        targetCode: () => 'es',
        phraseIds: ['p:3', 'p:3'],
      );
      expect(changed.name, 'Porto');
      expect(changed.sourceCode, isNull);
      expect(changed.targetCode, 'es');
      expect(changed.phraseIds, ['p:3']);
      expect(collection().copyWith(), collection());
    });
  });

  group('PhraseDraft', () {
    HistoryEntry entry({
      Language source = const Language(code: 'en', name: 'English'),
      Language target = const Language(code: 'pt', name: 'Portuguese'),
      String? detected,
      HistoryEntryKind kind = HistoryEntryKind.translation,
    }) => HistoryEntry(
      id: '1',
      text: ' Hello ',
      translation: ' Olá ',
      source: source,
      target: target,
      engineId: 'offline',
      engineName: 'Offline',
      createdAt: _time,
      detectedSource: detected,
      kind: kind,
    );

    test('fromHistory takes the detected language and the kind', () {
      final draft = PhraseDraft.fromHistory(
        entry(source: Language.auto, detected: 'fr'),
      );
      expect(draft.text, 'Hello');
      expect(draft.translation, 'Olá');
      expect(draft.sourceCode, 'fr');
      expect(draft.targetCode, 'pt');
      expect(draft.origin, PhraseOrigin.history);
      expect(
        PhraseDraft.fromHistory(entry(kind: HistoryEntryKind.dictionary))
            .origin,
        PhraseOrigin.dictionary,
      );
    });

    test('unknown and custom languages are und, never auto', () {
      expect(phraseLanguageOf(Language.auto), Phrase.unknownLanguage);
      expect(phraseLanguageOf(Language.auto, detected: 'auto'), 'und');
      expect(phraseLanguageOf(const Language.custom('Pirate')), 'und');
      expect(phraseLanguageOf(const Language(code: ' ', name: 'Blank')), 'und');
      expect(
        phraseLanguageOf(const Language(code: 'de', name: 'German')),
        'de',
      );
    });

    test('fromPhrase keeps the note, pronunciation and topic', () {
      final draft = PhraseDraft.fromPhrase(_phrase(note: 'n'));
      expect(draft.note, 'n');
      expect(draft.pronunciation, 'oh-LAH');
      expect(draft.topic, 'Basics');
      expect(draft.origin, PhraseOrigin.history);
      expect(draft.contentKey, _phrase().contentKey);
    });

    test('toPhrase trims and stamps', () {
      const draft = PhraseDraft(
        text: ' a ',
        translation: ' b ',
        sourceCode: 'en',
        targetCode: 'fr',
        note: ' note ',
      );
      final phrase = draft.toPhrase('p:9', _time);
      expect(phrase.id, 'p:9');
      expect(phrase.text, 'a');
      expect(phrase.translation, 'b');
      expect(phrase.note, 'note');
      expect(phrase.createdAt, _time);
      expect(phrase.updatedAt, _time);
      expect(draft.isEmpty, isFalse);
      expect(
        const PhraseDraft(
          text: 'a',
          translation: ' ',
          sourceCode: 'en',
          targetCode: 'fr',
        ).isEmpty,
        isTrue,
      );
    });
  });
}
