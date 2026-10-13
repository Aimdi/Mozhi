import 'dart:convert';

import 'package:flutter_test/flutter_test.dart';
import 'package:mozhi/core/key_value_store.dart';
import 'package:mozhi/history/data/history_repository.dart';
import 'package:mozhi/history/models/history_entry.dart';
import 'package:translation_repository/translation_repository.dart';

const _french = Language(code: 'fr', name: 'French');
const _german = Language(code: 'de', name: 'German');

HistoryEntry _entry(
  String id, {
  String? text,
  Language target = _french,
  String engineId = 'mozhi:google',
  int minute = 0,
  bool isFavorite = false,
}) => HistoryEntry(
  id: id,
  text: text ?? 'text $id',
  translation: 'translation $id',
  source: Language.auto,
  target: target,
  engineId: engineId,
  engineName: 'Engine',
  createdAt: DateTime(2026, 10, 13, 12, minute),
  isFavorite: isFavorite,
);

class _FailingWriteStore extends MemoryStore {
  @override
  Future<void> write(String key, String value) =>
      Future.error(StateError('disk full'));
}

void main() {
  group(HistoryRepository, () {
    late MemoryStore store;
    late HistoryRepository repository;

    List<String> storedIds() {
      final raw = store.values[HistoryRepository.storageKey]!;
      return [
        for (final json in jsonDecode(raw) as List<dynamic>)
          (json as Map<String, dynamic>)['id'] as String,
      ];
    }

    setUp(() {
      store = MemoryStore();
      repository = HistoryRepository(store: store);
    });

    test('defaults to the platform preferences and 1000 entries', () {
      final repository = HistoryRepository();

      expect(repository.store, isA<PreferencesStore>());
      expect(repository.maxEntries, 1000);
    });

    group('load', () {
      test('returns an empty list when nothing is stored', () async {
        expect(await repository.load(), isEmpty);
      });

      test('returns an empty list for corrupt JSON', () async {
        store.values[HistoryRepository.storageKey] = '{oops';

        expect(await repository.load(), isEmpty);
      });

      test('returns an empty list when the JSON is not a list', () async {
        store.values[HistoryRepository.storageKey] = '{"id": "1"}';

        expect(await repository.load(), isEmpty);
      });

      test('skips invalid entries', () async {
        store.values[HistoryRepository.storageKey] = jsonEncode([
          _entry('1').toJson(),
          {'id': 'broken'},
          'nope',
          _entry('2').toJson(),
        ]);

        expect(await repository.load(), [_entry('1'), _entry('2')]);
      });

      test('reloads from storage', () async {
        await repository.add(_entry('1'));
        store.values[HistoryRepository.storageKey] = jsonEncode([
          _entry('2').toJson(),
        ]);

        expect(await repository.load(), [_entry('2')]);
      });

      test('returns an unmodifiable list', () async {
        final entries = await repository.load();

        expect(() => entries.add(_entry('1')), throwsUnsupportedError);
      });
    });

    group('add', () {
      test('inserts entries newest first and persists them', () async {
        await repository.add(_entry('1'));
        final entries = await repository.add(_entry('2'));

        expect(entries, [_entry('2'), _entry('1')]);
        expect(storedIds(), ['2', '1']);
        expect(await HistoryRepository(store: store).load(), [
          _entry('2'),
          _entry('1'),
        ]);
      });

      test('works without an explicit load', () async {
        store.values[HistoryRepository.storageKey] = jsonEncode([
          _entry('1').toJson(),
        ]);

        final entries = await repository.add(_entry('2'));

        expect(entries, [_entry('2'), _entry('1')]);
      });

      test('replaces the newest entry for the same text, target and '
          'engine', () async {
        await repository.add(_entry('1', text: 'Hello'));
        await repository.add(_entry('2', text: 'Bye'));

        final entries = await repository.add(_entry('3', text: 'Bye '));

        expect(entries, [
          _entry('3', text: 'Bye '),
          _entry('1', text: 'Hello'),
        ]);
      });

      test('keeps the favourite flag of a replaced entry', () async {
        await repository.add(_entry('1', text: 'Hi', isFavorite: true));

        final entries = await repository.add(_entry('2', text: 'Hi'));

        expect(entries, [_entry('2', text: 'Hi', isFavorite: true)]);
      });

      test('does not replace when the target or engine differ', () async {
        await repository.add(_entry('1', text: 'Hi'));
        await repository.add(_entry('2', text: 'Hi', target: _german));

        final entries = await repository.add(
          _entry('3', text: 'Hi', target: _german, engineId: 'ai:p1'),
        );

        expect(entries.map((e) => e.id), ['3', '2', '1']);
      });

      test('does not replace older entries with the same text', () async {
        await repository.add(_entry('1', text: 'Hi'));
        await repository.add(_entry('2', text: 'Other'));

        final entries = await repository.add(_entry('3', text: 'Hi'));

        expect(entries.map((e) => e.id), ['3', '2', '1']);
      });

      test('moves an entry with an existing id to the front', () async {
        await repository.add(_entry('1'));
        await repository.add(_entry('2'));

        final entries = await repository.add(_entry('1', text: 'updated'));

        expect(entries, [_entry('1', text: 'updated'), _entry('2')]);
      });

      test('removes a duplicate id when replacing the newest entry', () async {
        await repository.add(_entry('1', text: 'A'));
        await repository.add(_entry('2', text: 'B'));

        final entries = await repository.add(_entry('1', text: 'B'));

        expect(entries, [_entry('1', text: 'B')]);
      });

      test('evicts the oldest non-favourites beyond maxEntries', () async {
        final repository = HistoryRepository(store: store, maxEntries: 2);
        await repository.add(_entry('1', isFavorite: true));
        await repository.add(_entry('2'));
        await repository.add(_entry('3'));

        final entries = await repository.add(_entry('4'));

        expect(entries.map((e) => e.id), ['4', '3', '1']);
        expect(storedIds(), ['4', '3', '1']);
      });

      test('never evicts favourites', () async {
        final repository = HistoryRepository(store: store, maxEntries: 1);
        await repository.add(_entry('1', isFavorite: true));
        await repository.add(_entry('2', isFavorite: true));

        final entries = await repository.add(_entry('3'));

        expect(entries.map((e) => e.id), ['3', '2', '1']);
      });

      test('caps entries on load as well', () async {
        store.values[HistoryRepository.storageKey] = jsonEncode([
          for (var i = 0; i < 5; i++) _entry('$i').toJson(),
        ]);

        final entries = await HistoryRepository(
          store: store,
          maxEntries: 3,
        ).load();

        expect(entries.map((e) => e.id), ['0', '1', '2']);
      });

      test('serialises concurrent additions', () async {
        await Future.wait([
          for (var i = 0; i < 5; i++) repository.add(_entry('$i')),
        ]);

        expect(storedIds(), ['4', '3', '2', '1', '0']);
      });

      test('propagates storage errors and keeps the previous state', () async {
        final repository = HistoryRepository(store: _FailingWriteStore());

        await expectLater(repository.add(_entry('1')), throwsStateError);
        expect(await repository.exportJson(), '[]');
      });
    });

    group('toggleFavorite', () {
      test('flips the favourite flag of one entry', () async {
        await repository.add(_entry('1'));
        await repository.add(_entry('2'));

        var entries = await repository.toggleFavorite('1');
        expect(entries, [_entry('2'), _entry('1', isFavorite: true)]);

        entries = await repository.toggleFavorite('1');
        expect(entries, [_entry('2'), _entry('1')]);
      });

      test('ignores unknown ids', () async {
        await repository.add(_entry('1'));

        expect(await repository.toggleFavorite('x'), [_entry('1')]);
      });
    });

    group('delete', () {
      test('removes the entry with the id', () async {
        await repository.add(_entry('1'));
        await repository.add(_entry('2'));

        expect(await repository.delete('1'), [_entry('2')]);
        expect(storedIds(), ['2']);
      });
    });

    group('clear', () {
      setUp(() async {
        await repository.add(_entry('1', isFavorite: true));
        await repository.add(_entry('2'));
      });

      test('removes everything by default', () async {
        expect(await repository.clear(), isEmpty);
        expect(storedIds(), isEmpty);
      });

      test('keeps favourites when asked to', () async {
        expect(await repository.clear(keepFavorites: true), [
          _entry('1', isFavorite: true),
        ]);
      });
    });

    group('exportJson', () {
      test('returns a pretty JSON array of all entries', () async {
        await repository.add(_entry('1'));
        await repository.add(_entry('2', isFavorite: true));

        final json = await repository.exportJson();

        expect(json, contains('\n  {'));
        expect(jsonDecode(json), [
          _entry('2', isFavorite: true).toJson(),
          _entry('1').toJson(),
        ]);
      });

      test('returns an empty array without history', () async {
        expect(await repository.exportJson(), '[]');
      });
    });

    group('importJson', () {
      test('merges entries, dedupes by id and sorts newest first', () async {
        await repository.add(_entry('a', minute: 10, text: 'local'));
        await repository.add(_entry('b', minute: 30));

        final entries = await repository.importJson(
          jsonEncode([
            _entry('a', minute: 10, text: 'imported').toJson(),
            _entry('c', minute: 20).toJson(),
            _entry('d', minute: 40, isFavorite: true).toJson(),
          ]),
        );

        expect(entries, [
          _entry('d', minute: 40, isFavorite: true),
          _entry('b', minute: 30),
          _entry('c', minute: 20),
          _entry('a', minute: 10, text: 'local'),
        ]);
        expect(storedIds(), ['d', 'b', 'c', 'a']);
      });

      test('round-trips with exportJson', () async {
        await repository.add(_entry('1', minute: 1));
        await repository.add(_entry('2', minute: 2, isFavorite: true));
        final exported = await repository.exportJson();

        final other = HistoryRepository(store: MemoryStore());
        final entries = await other.importJson(exported);

        expect(entries, await repository.load());
      });

      test('applies the entry cap', () async {
        final repository = HistoryRepository(store: store, maxEntries: 2);

        final entries = await repository.importJson(
          jsonEncode([
            for (var i = 0; i < 4; i++) _entry('$i', minute: i).toJson(),
          ]),
        );

        expect(entries.map((e) => e.id), ['3', '2']);
      });

      test('skips invalid elements of an otherwise valid array', () async {
        final entries = await repository.importJson(
          jsonEncode([
            _entry('1').toJson(),
            {'id': 'broken'},
            42,
          ]),
        );

        expect(entries, [_entry('1')]);
      });

      test('accepts an empty array', () async {
        await repository.add(_entry('1'));

        expect(await repository.importJson('[]'), [_entry('1')]);
      });

      test('throws a FormatException for invalid JSON', () async {
        await expectLater(
          repository.importJson('not json'),
          throwsFormatException,
        );
      });

      test('throws a FormatException when the JSON is not an array', () async {
        await expectLater(
          repository.importJson('{"entries": []}'),
          throwsFormatException,
        );
      });

      test('throws a FormatException without any valid entry', () async {
        await expectLater(
          repository.importJson('[{"id": "1"}, 2]'),
          throwsFormatException,
        );
        expect(store.values, isEmpty);
      });
    });
  });
}
