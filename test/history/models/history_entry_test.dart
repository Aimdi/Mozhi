import 'dart:convert';

import 'package:flutter_test/flutter_test.dart';
import 'package:mozhi/history/models/history_entry.dart';
import 'package:translation_repository/translation_repository.dart';

final _entry = HistoryEntry(
  id: '1',
  text: 'Hello',
  translation: 'Bonjour',
  source: Language.auto,
  target: const Language(code: 'fr', name: 'French', nativeName: 'Français'),
  engineId: 'mozhi:google',
  engineName: 'Google',
  createdAt: DateTime(2026, 10, 13, 19, 48, 21, 123, 456),
  detectedSource: 'en',
);

Map<String, dynamic> _json([Map<String, dynamic> overrides = const {}]) => {
  ...jsonDecode(jsonEncode(_entry.toJson())) as Map<String, dynamic>,
  ...overrides,
};

void main() {
  group(HistoryEntry, () {
    test('supports value equality', () {
      expect(_entry, equals(_entry.copyWith()));
      expect(_entry, isNot(equals(_entry.copyWith(isFavorite: true))));
    });

    test('copyWith replaces the favourite flag and translation', () {
      final copy = _entry.copyWith(isFavorite: true, translation: 'Salut');

      expect(copy.isFavorite, isTrue);
      expect(copy.translation, 'Salut');
      expect(copy.id, _entry.id);
      expect(copy.text, _entry.text);
      expect(copy.source, _entry.source);
      expect(copy.target, _entry.target);
      expect(copy.engineId, _entry.engineId);
      expect(copy.engineName, _entry.engineName);
      expect(copy.createdAt, _entry.createdAt);
      expect(copy.detectedSource, _entry.detectedSource);
    });

    test('copyWith replaces the text', () {
      final copy = _entry.copyWith(text: 'Hi');

      expect(copy.text, 'Hi');
      expect(copy, equals(_entry.copyWith(text: 'Hi')));
      expect(copy.translation, _entry.translation);
      expect(copy.id, _entry.id);
      expect(copy.createdAt, _entry.createdAt);
    });

    group('toJson', () {
      test('writes createdAt as UTC ISO-8601', () {
        final json = _entry.toJson();

        expect(json['createdAt'], _entry.createdAt.toUtc().toIso8601String());
        expect(json['createdAt'], endsWith('Z'));
      });

      test('omits a missing detected source', () {
        final entry = HistoryEntry.fromJson(_json({'detectedSource': null}));

        expect(entry.toJson(), isNot(contains('detectedSource')));
      });
    });

    group('fromJson', () {
      test('round-trips through JSON', () {
        expect(HistoryEntry.fromJson(_json()), equals(_entry));
      });

      test('round-trips favourites and custom languages', () {
        final entry = HistoryEntry(
          id: '2',
          text: 'Hello',
          translation: 'Ahoy',
          source: const Language(code: 'en', name: 'English'),
          target: const Language.custom('Pirate speak'),
          engineId: 'ai:p1',
          engineName: 'Claude',
          createdAt: DateTime(2026),
          isFavorite: true,
        );

        final restored = HistoryEntry.fromJson(
          jsonDecode(jsonEncode(entry.toJson())) as Map<String, dynamic>,
        );

        expect(restored, equals(entry));
        expect(restored.target.isCustom, isTrue);
        expect(restored.isFavorite, isTrue);
      });

      test('reads UTC timestamps as local time', () {
        final createdAt = DateTime.utc(2026, 5, 6, 7, 8, 9);

        final entry = HistoryEntry.fromJson(
          _json({'createdAt': createdAt.toIso8601String()}),
        );

        expect(entry.createdAt.isUtc, isFalse);
        expect(entry.createdAt.isAtSameMomentAs(createdAt), isTrue);
      });

      test('accepts createdAt in milliseconds since the epoch', () {
        final createdAt = DateTime(2026, 1, 2, 3, 4, 5);

        final entry = HistoryEntry.fromJson(
          _json({'createdAt': createdAt.millisecondsSinceEpoch}),
        );

        expect(entry.createdAt, createdAt);
      });

      test('falls back to the engine id for a missing engine name', () {
        final entry = HistoryEntry.fromJson(_json({'engineName': ''}));

        expect(entry.engineName, 'mozhi:google');
      });

      test('treats a blank detected source and missing favourite as unset', () {
        final json = _json({'detectedSource': ''})..remove('isFavorite');

        final entry = HistoryEntry.fromJson(json);

        expect(entry.detectedSource, isNull);
        expect(entry.isFavorite, isFalse);
      });

      for (final field in [
        'id',
        'text',
        'translation',
        'source',
        'target',
        'engineId',
        'createdAt',
      ]) {
        test('throws a FormatException when $field is missing', () {
          expect(
            () => HistoryEntry.fromJson(_json()..remove(field)),
            throwsFormatException,
          );
        });
      }

      test('throws a FormatException for an invalid createdAt', () {
        expect(
          () => HistoryEntry.fromJson(_json({'createdAt': 'yesterday'})),
          throwsFormatException,
        );
      });

      test('throws a FormatException for an invalid language', () {
        expect(
          () => HistoryEntry.fromJson(
            _json({
              'target': {'code': 'fr'},
            }),
          ),
          throwsFormatException,
        );
      });
    });

    group('kind', () {
      final lookUp = HistoryEntry(
        id: 'dictionary:1',
        kind: HistoryEntryKind.dictionary,
        text: 'gato',
        translation: 'noun · A small domesticated feline.',
        source: const Language(code: 'es', name: 'Spanish'),
        target: const Language(code: 'en', name: 'English'),
        engineId: 'ai:claude',
        engineName: 'Claude',
        createdAt: DateTime(2026, 10, 20, 9, 30),
        verbosity: DictionaryVerbosity.comprehensive,
      );

      test('is translation by default', () {
        expect(_entry.kind, HistoryEntryKind.translation);
        expect(_entry.isDictionary, isFalse);
        expect(_entry.verbosity, isNull);
        expect(lookUp.isDictionary, isTrue);
      });

      test('JSON without a kind (older versions) is a translation', () {
        final json = _json()
          ..remove('kind')
          ..remove('verbosity');

        final entry = HistoryEntry.fromJson(json);

        expect(entry.kind, HistoryEntryKind.translation);
        expect(entry, _entry);
      });

      test('translations are written without kind or detail level', () {
        final json = _entry.toJson();

        expect(json, isNot(contains('kind')));
        expect(json, isNot(contains('verbosity')));
        expect(HistoryEntry.fromJson(_json({'kind': 'translation'})), _entry);
      });

      test('look-ups round-trip with their kind and detail level', () {
        final json = lookUp.toJson();

        expect(json['kind'], 'dictionary');
        expect(json['verbosity'], 'comprehensive');
        expect(
          HistoryEntry.fromJson(
            jsonDecode(jsonEncode(json)) as Map<String, dynamic>,
          ),
          lookUp,
        );
      });

      test('a look-up without a detail level round-trips', () {
        final entry = HistoryEntry(
          id: lookUp.id,
          kind: HistoryEntryKind.dictionary,
          text: lookUp.text,
          translation: '',
          source: Language.auto,
          target: lookUp.target,
          engineId: lookUp.engineId,
          engineName: lookUp.engineName,
          createdAt: lookUp.createdAt,
        );

        expect(entry.toJson(), isNot(contains('verbosity')));
        expect(HistoryEntry.fromJson(entry.toJson()), entry);
      });

      test('ignores an unknown detail level, and any on a translation', () {
        expect(
          HistoryEntry.fromJson({...lookUp.toJson(), 'verbosity': 'verbose'})
              .verbosity,
          isNull,
        );
        expect(
          HistoryEntry.fromJson(_json({'verbosity': 'concise'})).verbosity,
          isNull,
        );
      });

      test('throws a FormatException for an unknown kind', () {
        expect(
          () => HistoryEntry.fromJson(_json({'kind': 'phrasebook'})),
          throwsFormatException,
        );
        expect(
          () => HistoryEntry.fromJson(_json({'kind': 1})),
          throwsFormatException,
        );
      });

      test('copyWith keeps the kind and detail level and can set the id', () {
        final copy = lookUp.copyWith(id: '2', isFavorite: true);

        expect(copy.id, '2');
        expect(copy.isFavorite, isTrue);
        expect(copy.kind, HistoryEntryKind.dictionary);
        expect(copy.verbosity, DictionaryVerbosity.comprehensive);
        expect(copy, isNot(lookUp));
      });

      group('isLookUpOf', () {
        const spanish = Language(code: 'es', name: 'Español');
        const english = Language(code: 'en', name: 'English');

        test('matches the word trimmed, with runs of spaces as one', () {
          final phrase = lookUp.copyWith(text: ' buenos   días ');

          expect(
            phrase.isLookUpOf('buenos días', source: spanish, target: english),
            isTrue,
          );
          expect(
            lookUp.isLookUpOf('gato', source: spanish, target: english),
            isTrue,
          );
        });

        test('needs the same case and languages', () {
          expect(
            lookUp.isLookUpOf('Gato', source: spanish, target: english),
            isFalse,
          );
          expect(
            lookUp.isLookUpOf('gato', source: Language.auto, target: english),
            isFalse,
          );
          expect(
            lookUp.isLookUpOf('gato', source: spanish, target: spanish),
            isFalse,
          );
        });

        test('never matches a translation', () {
          final translation = HistoryEntry.fromJson(
            _json({
              'text': 'gato',
              'source': spanish.toJson(),
              'target': english.toJson(),
            }),
          );

          expect(
            translation.isLookUpOf('gato', source: spanish, target: english),
            isFalse,
          );
          expect(lookUp.isSameLookUp(translation), isFalse);
          expect(translation.isSameLookUp(lookUp), isFalse);
        });

        test('isSameLookUp compares two look-ups', () {
          expect(lookUp.isSameLookUp(lookUp.copyWith(id: '2')), isTrue);
          expect(lookUp.isSameLookUp(lookUp.copyWith(text: 'perro')), isFalse);
        });
      });
    });
  });
}
