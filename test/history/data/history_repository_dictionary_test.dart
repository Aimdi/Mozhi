import 'dart:convert';

import 'package:flutter_test/flutter_test.dart';
import 'package:mozhi/core/key_value_store.dart';
import 'package:mozhi/history/data/history_repository.dart';
import 'package:mozhi/history/models/history_entry.dart';
import 'package:translation_repository/translation_repository.dart';

const _spanish = Language(code: 'es', name: 'Spanish');
const _english = Language(code: 'en', name: 'English');
const _french = Language(code: 'fr', name: 'French');

/// The history key of the tests' key store.
final _key = List<int>.generate(HistoryCipher.keyLength, (i) => i * 3 % 256);

DateTime _at(int minute) => DateTime(2026, 10, 20, 12, minute);

HistoryEntry _lookUp(
  String id, {
  String word = 'hola',
  String summary = 'interjection · A greeting.',
  Language source = _spanish,
  Language target = _english,
  int minute = 0,
  bool isFavorite = false,
  DictionaryVerbosity? verbosity = DictionaryVerbosity.standard,
  String engineId = 'ai:claude',
}) => HistoryEntry(
  id: id,
  kind: HistoryEntryKind.dictionary,
  text: word,
  translation: summary,
  source: source,
  target: target,
  engineId: engineId,
  engineName: 'Claude',
  createdAt: _at(minute),
  verbosity: verbosity,
  isFavorite: isFavorite,
);

HistoryEntry _translation(
  String id, {
  String text = 'hola',
  String translation = 'hello',
  Language source = _spanish,
  Language target = _english,
  int minute = 0,
  bool isFavorite = false,
  String engineId = 'ai:claude',
}) => HistoryEntry(
  id: id,
  text: text,
  translation: translation,
  source: source,
  target: target,
  engineId: engineId,
  engineName: 'Claude',
  createdAt: _at(minute),
  isFavorite: isFavorite,
);

void main() {
  group('HistoryRepository with dictionary look-ups', () {
    late MemoryStore store;
    late MemoryStore keys;
    late HistoryRepository repository;

    HistoryRepository build({
      int maxEntries = 1000,
      DateTime Function()? clock,
    }) => HistoryRepository(
      store: store,
      keyStore: keys,
      maxEntries: maxEntries,
      clock: clock,
    );

    /// The decrypted JSON list stored in [store].
    Future<List<dynamic>> stored() async => jsonDecode(
      await const HistoryCipher().decrypt(
        store.values[HistoryRepository.storageKey]!,
        _key,
      ),
    ) as List<dynamic>;

    /// [json] stored the way the repository stores it.
    Future<void> storeJson(Object json) async {
      store.values[HistoryRepository.storageKey] = await const HistoryCipher()
          .encrypt(jsonEncode(json), _key);
    }

    setUp(() {
      store = MemoryStore();
      keys = MemoryStore({HistoryRepository.keyStorageKey: base64Encode(_key)});
      repository = build();
    });

    group('add', () {
      test('stores look-ups with their kind and detail level', () async {
        await repository.add(_lookUp('1'));

        final json = (await stored()).single as Map<String, dynamic>;
        expect(json['kind'], 'dictionary');
        expect(json['verbosity'], 'standard');
        expect(await build().load(), [_lookUp('1')]);
      });

      test('a new look-up of the same word and languages updates the '
          'earlier entry wherever it is', () async {
        await repository.add(_lookUp('1', minute: 1));
        await repository.add(_translation('2', text: 'gato', minute: 2));
        await repository.add(_lookUp('3', word: 'perro', minute: 3));

        final entries = await repository.add(
          _lookUp(
            '4',
            word: '  hola ',
            summary: 'interjection · Hello.',
            minute: 4,
            verbosity: DictionaryVerbosity.comprehensive,
          ),
        );

        expect(entries.map((e) => e.id), ['1', '3', '2']);
        final updated = entries.first;
        // The existing id, the new look-up's word, summary, level and time.
        expect(updated.text, '  hola ');
        expect(updated.translation, 'interjection · Hello.');
        expect(updated.verbosity, DictionaryVerbosity.comprehensive);
        expect(updated.createdAt, _at(4));
        expect(await stored(), hasLength(3));
      });

      test('keeps the favourite of the updated look-up', () async {
        await repository.add(_lookUp('1', isFavorite: true));
        await repository.add(_translation('2', text: 'gato', minute: 1));

        final entries = await repository.add(_lookUp('3', minute: 2));

        expect(entries.map((e) => e.id), ['1', '2']);
        expect(entries.first.isFavorite, isTrue);
      });

      test('a favourite look-up stars the earlier entry', () async {
        await repository.add(_lookUp('1'));

        final entries = await repository.add(
          _lookUp('2', minute: 1, isFavorite: true),
        );

        expect(entries, [_lookUp('1', minute: 1, isFavorite: true)]);
      });

      test('keeps look-ups of another word or other languages', () async {
        await repository.add(_lookUp('1'));
        await repository.add(_lookUp('2', word: 'Hola', minute: 1));
        await repository.add(_lookUp('3', target: _french, minute: 2));
        await repository.add(_lookUp('4', source: Language.auto, minute: 3));

        expect((await repository.load()).map((e) => e.id), [
          '4',
          '3',
          '2',
          '1',
        ]);
      });

      test('never merges a translation into a look-up', () async {
        await repository.add(_lookUp('1'));

        final entries = await repository.add(_translation('2', minute: 1));

        expect(entries.map((e) => e.id), ['2', '1']);
        expect(entries.map((e) => e.kind), [
          HistoryEntryKind.translation,
          HistoryEntryKind.dictionary,
        ]);
      });

      test('never merges a look-up into a translation', () async {
        await repository.add(_translation('1'));

        final entries = await repository.add(_lookUp('2', minute: 1));

        expect(entries.map((e) => e.id), ['2', '1']);
      });

      test('never treats a look-up as a typing refinement', () async {
        await repository.add(_lookUp('1', word: 'hol'));

        // A translation of a longer text right after it.
        final entries = await repository.add(_translation('2'));

        expect(entries.map((e) => e.id), ['2', '1']);
      });

      test(
        'counts look-ups in maxEntries and never evicts favourites',
        () async {
          final repository = build(maxEntries: 2);
          await repository.add(_lookUp('1', word: 'uno', isFavorite: true));
          await repository.add(_lookUp('2', word: 'dos', minute: 1));
          await repository.add(_translation('3', minute: 2));

          final entries = await repository.add(
            _lookUp('4', word: 'cuatro', minute: 3),
          );

          expect(entries.map((e) => e.id), ['4', '3', '1']);
        },
      );

      test('drops expired look-ups but keeps favourite ones', () async {
        final repository = build(clock: () => _at(60));
        await repository.add(_lookUp('1', word: 'uno', isFavorite: true));
        await repository.add(_lookUp('2', word: 'dos'));

        final entries = await repository.add(
          _lookUp('3', word: 'tres', minute: 59),
          maxAge: const Duration(minutes: 30),
        );

        expect(entries.map((e) => e.id), ['3', '1']);
      });
    });

    group('migration', () {
      test(
        'history stored before kinds existed loads as translations',
        () async {
          // As stored by older versions: no kind, no verbosity.
          await storeJson([
            {
              'id': '1',
              'text': 'hola',
              'translation': 'hello',
              'source': {'code': 'es', 'name': 'Spanish'},
              'target': {'code': 'en', 'name': 'English'},
              'engineId': 'mozhi:google',
              'engineName': 'Google',
              'createdAt': '2026-10-20T10:00:00.000Z',
              'isFavorite': true,
            },
          ]);

          final entries = await repository.load();

          expect(entries.single.kind, HistoryEntryKind.translation);
          expect(entries.single.isFavorite, isTrue);
          expect(entries.single.verbosity, isNull);
        },
      );

      test('translations are stored exactly as before', () async {
        await repository.add(_translation('1'));

        final json = (await stored()).single as Map<String, dynamic>;
        expect(json.keys, isNot(contains('kind')));
        expect(json.keys, isNot(contains('verbosity')));
        expect(json, _translation('1').toJson());
      });

      test('entries of an unknown kind are skipped', () async {
        await storeJson([
          {..._lookUp('1').toJson(), 'kind': 'phrasebook'},
          _lookUp('2', word: 'perro').toJson(),
        ]);

        expect((await repository.load()).map((e) => e.id), ['2']);
      });
    });

    group('export and import', () {
      test('export includes look-ups and imports them back', () async {
        await repository.add(_translation('1'));
        await repository.add(_lookUp('2', minute: 1, isFavorite: true));
        final exported = await repository.exportJson();

        expect(exported, contains('"kind": "dictionary"'));
        store = MemoryStore();
        final result = await build().importJson(exported);

        expect(result.added, 2);
        expect(result.entries, [
          _lookUp('2', minute: 1, isFavorite: true),
          _translation('1'),
        ]);
      });

      test(
        'imports JSON exported before kinds existed as translations',
        () async {
          final result = await repository.importJson(
            jsonEncode([
              {
                'id': '1',
                'text': 'gato',
                'translation': 'cat',
                'source': {'code': 'es', 'name': 'Spanish'},
                'target': {'code': 'en', 'name': 'English'},
                'engineId': 'mozhi:google',
                'engineName': 'Google',
                'createdAt': '2026-10-20T10:00:00.000Z',
                'isFavorite': false,
              },
            ]),
          );

          expect(result.added, 1);
          expect(result.entries.single.kind, HistoryEntryKind.translation);
        },
      );

      test('an existing look-up wins over an imported one of the same '
          'word, taking its favourite', () async {
        await repository.add(_lookUp('1', summary: 'local'));

        final result = await repository.importJson(
          jsonEncode([
            _lookUp(
              '2',
              summary: 'imported',
              minute: 5,
              isFavorite: true,
            ).toJson(),
          ]),
        );

        expect(result.added, 0);
        expect(result.entries, [
          _lookUp('1', summary: 'local', isFavorite: true),
        ]);
      });

      test('keeps an existing look-up as it is for a non-favourite '
          'import', () async {
        await repository.add(_lookUp('1', isFavorite: true));

        final result = await repository.importJson(
          jsonEncode([_lookUp('2', minute: 5).toJson()]),
        );

        expect(result.entries, [_lookUp('1', isFavorite: true)]);
      });

      test(
        'keeps the newer of two imported look-ups of the same word',
        () async {
          final result = await repository.importJson(
            jsonEncode([
              _lookUp('1', summary: 'older', isFavorite: true).toJson(),
              _lookUp('2', summary: 'newer', minute: 5).toJson(),
              _lookUp('3', summary: 'oldest', minute: -5).toJson(),
            ]),
          );

          expect(result.added, 1);
          expect(result.entries, [
            _lookUp('2', summary: 'newer', minute: 5, isFavorite: true),
          ]);
        },
      );
    });

    test('toggleFavorite, delete, restore and clear handle look-ups', () async {
      await repository.add(_lookUp('1'));
      await repository.add(_translation('2', minute: 1));

      var entries = await repository.toggleFavorite('1');
      expect(entries.last.isFavorite, isTrue);

      entries = await repository.delete('1');
      expect(entries.map((e) => e.id), ['2']);

      entries = await repository.restore(_lookUp('1', isFavorite: true));
      expect(entries.map((e) => e.id), ['2', '1']);

      entries = await repository.clear(keepFavorites: true);
      expect(entries, [_lookUp('1', isFavorite: true)]);

      expect(await repository.clear(), isEmpty);
    });

    group('restore', () {
      test('merges with a look-up of the same word made since', () async {
        // Undo of deleting "hola", after it was looked up again.
        final deleted = _lookUp('1', minute: 1, isFavorite: true);
        await repository.add(deleted);
        await repository.add(_translation('2', minute: 2));
        await repository.delete('1');
        final again = _lookUp('3', summary: 'newer', minute: 3);
        await repository.add(again);

        final entries = await repository.restore(deleted);

        // One entry: the newer look-up, a favourite as the deleted one was.
        expect(entries, [
          again.copyWith(isFavorite: true),
          _translation('2', minute: 2),
        ]);
        expect(await stored(), hasLength(2));
      });

      test(
        'the restored look-up replaces an older one of the same word',
        () async {
          await repository.add(_lookUp('1', minute: 1, isFavorite: true));
          await repository.add(_translation('2', minute: 2));

          final entries = await repository.restore(
            _lookUp('3', summary: 'newer', minute: 3),
          );

          expect(entries, [
            _lookUp('3', summary: 'newer', minute: 3, isFavorite: true),
            _translation('2', minute: 2),
          ]);
        },
      );

      test('keeps look-ups of other words and translations apart', () async {
        await repository.add(_lookUp('1', word: 'perro', minute: 1));
        await repository.add(_translation('2', text: 'hola', minute: 2));

        final entries = await repository.restore(_lookUp('3', minute: 3));

        expect(entries.map((e) => e.id), ['3', '2', '1']);
      });

      test('restoreFavorite stars the look-up a new look-up updated', () async {
        final starred = _lookUp('1', isFavorite: true);
        await repository.add(starred);
        await repository.toggleFavorite('1');
        // Looked up again: the entry keeps its id and gets the new summary.
        await repository.add(_lookUp('2', summary: 'newer', minute: 2));

        final entries = await repository.restoreFavorite(starred);

        expect(entries, [
          _lookUp('1', summary: 'newer', minute: 2, isFavorite: true),
        ]);
      });
    });
  });
}
