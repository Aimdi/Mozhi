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
  String? translation,
  Language source = Language.auto,
  Language target = _french,
  String engineId = 'mozhi:google',
  int minute = 0,
  int second = 0,
  bool isFavorite = false,
}) => HistoryEntry(
  id: id,
  text: text ?? 'text $id',
  translation: translation ?? 'translation $id',
  source: source,
  target: target,
  engineId: engineId,
  engineName: 'Engine',
  createdAt: DateTime(2026, 10, 13, 12, minute, second),
  isFavorite: isFavorite,
);

/// Length of the stored JSON of [entry].
int _length(HistoryEntry entry) => jsonEncode(entry.toJson()).length;

class _FailingWriteStore extends MemoryStore {
  int attempts = 0;

  @override
  Future<void> write(String key, String value) {
    attempts++;
    return Future.error(StateError('disk full'));
  }
}

/// A [MemoryStore] that counts writes.
class _CountingStore extends MemoryStore {
  int writes = 0;

  @override
  Future<void> write(String key, String value) {
    writes++;
    return super.write(key, value);
  }
}

class _QuotaExceeded implements Exception {
  @override
  String toString() =>
      "QuotaExceededError: Failed to execute 'setItem' on 'Storage': "
      'exceeded the quota.';
}

/// A [MemoryStore] that rejects values longer than [limit] like a full
/// browser `localStorage`.
class _QuotaStore extends MemoryStore {
  new(this.limit);

  final int limit;
  final List<int> attempts = [];

  @override
  Future<void> write(String key, String value) async {
    attempts.add(value.length);
    if (value.length > limit) throw _QuotaExceeded();
    await super.write(key, value);
  }
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
      expect(repository.maxStoredLength, 1000000);
      expect(repository.maxTextLength, 20000);
      expect(repository.refinementWindow, const Duration(seconds: 30));
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

      test('keeps the favourite flag of a replaced entry with the same '
          'translation', () async {
        await repository.add(
          _entry('1', text: 'Hi', translation: 'Hallo', isFavorite: true),
        );

        final entries = await repository.add(
          _entry('2', text: 'Hi', translation: 'Hallo '),
        );

        expect(entries, [
          _entry('2', text: 'Hi', translation: 'Hallo ', isFavorite: true),
        ]);
      });

      test('never overwrites a favourite with a different translation '
          '(regression)', () async {
        await repository.add(
          _entry(
            '1',
            text: 'How are you',
            translation: 'Wie geht es Ihnen?',
            isFavorite: true,
          ),
        );

        final entries = await repository.add(
          _entry('2', text: 'How are you', translation: "Wie geht's dir?"),
        );

        expect(entries, [
          _entry('2', text: 'How are you', translation: "Wie geht's dir?"),
          _entry(
            '1',
            text: 'How are you',
            translation: 'Wie geht es Ihnen?',
            isFavorite: true,
          ),
        ]);
      });

      test('still replaces a non-favourite with a different '
          'translation', () async {
        await repository.add(_entry('1', text: 'Hi', translation: 'Hallo'));

        final entries = await repository.add(
          _entry('2', text: 'Hi', translation: 'Servus'),
        );

        expect(entries, [_entry('2', text: 'Hi', translation: 'Servus')]);
      });

      test('does not replace when the source differs (regression)', () async {
        const english = Language(code: 'en', name: 'English');
        const norwegian = Language(code: 'no', name: 'Norwegian');
        await repository.add(
          _entry('1', text: 'gift', source: english, target: _german),
        );

        final entries = await repository.add(
          _entry('2', text: 'gift', source: norwegian, target: _german),
        );

        expect(entries.map((e) => e.id), ['2', '1']);
      });

      group('typing refinements (regression)', () {
        test('replace the newest entry when one text extends the '
            'other', () async {
          await repository.add(_entry('1', text: 'Good'));
          await repository.add(_entry('2', text: 'Good mor', second: 5));

          final entries = await repository.add(
            _entry('3', text: ' Good morning', second: 10),
          );

          expect(entries, [_entry('3', text: ' Good morning', second: 10)]);
          expect(storedIds(), ['3']);
        });

        test('replace the newest entry when the text was shortened', () async {
          await repository.add(_entry('1', text: 'Good morning'));

          final entries = await repository.add(
            _entry('2', text: 'Good', second: 20),
          );

          expect(entries.map((e) => e.id), ['2']);
        });

        test('work with createdAt in either order', () async {
          await repository.add(_entry('1', text: 'Good', second: 30));

          final entries = await repository.add(
            _entry('2', text: 'Good morning', second: 5),
          );

          expect(entries.map((e) => e.id), ['2']);
        });

        test('are kept outside the refinement window', () async {
          await repository.add(_entry('1', text: 'Good'));

          final entries = await repository.add(
            _entry('2', text: 'Good morning', second: 31),
          );

          expect(entries.map((e) => e.id), ['2', '1']);
        });

        test('honour a custom refinement window', () async {
          final repository = HistoryRepository(
            store: store,
            refinementWindow: const Duration(minutes: 5),
          );
          await repository.add(_entry('1', text: 'Good'));

          final entries = await repository.add(
            _entry('2', text: 'Good morning', minute: 4),
          );

          expect(entries.map((e) => e.id), ['2']);
        });

        test('never replace a favourite', () async {
          await repository.add(_entry('1', text: 'Good', isFavorite: true));

          final entries = await repository.add(
            _entry('2', text: 'Good morning', second: 5),
          );

          expect(entries.map((e) => e.id), ['2', '1']);
        });

        test('need the same source, target and engine', () async {
          await repository.add(_entry('1', text: 'Good'));
          await repository.add(
            _entry('2', text: 'Good m', target: _german, second: 1),
          );
          await repository.add(
            _entry(
              '3',
              text: 'Good mo',
              target: _german,
              engineId: 'ai:p1',
              second: 2,
            ),
          );

          final entries = await repository.add(
            _entry(
              '4',
              text: 'Good mor',
              source: const Language(code: 'en', name: 'English'),
              target: _german,
              engineId: 'ai:p1',
              second: 3,
            ),
          );

          expect(entries.map((e) => e.id), ['4', '3', '2', '1']);
        });

        test('ignore texts that are not prefixes of each other', () async {
          await repository.add(_entry('1', text: 'Good morning'));

          final entries = await repository.add(
            _entry('2', text: 'Good evening', second: 5),
          );

          expect(entries.map((e) => e.id), ['2', '1']);
        });
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
        final store = _FailingWriteStore();
        final repository = HistoryRepository(store: store);

        await expectLater(repository.add(_entry('1')), throwsStateError);
        expect(await repository.exportJson(), '[]');
        expect(store.attempts, 1);
      });
    });

    group('size limits (regression)', () {
      test('truncates long texts and translations', () async {
        final repository = HistoryRepository(store: store, maxTextLength: 10);

        final entries = await repository.add(
          _entry('1', text: 'a' * 11, translation: 'b' * 10),
        );

        expect(entries.single.text, '${'a' * 9}…');
        expect(entries.single.translation, 'b' * 10);
        expect(
          (jsonDecode(
            store.values[HistoryRepository.storageKey]!,
          ) as List<dynamic>).single,
          containsPair('text', '${'a' * 9}…'),
        );
      });

      test('does not split surrogate pairs when truncating', () async {
        final repository = HistoryRepository(store: store, maxTextLength: 4);

        final entries = await repository.add(
          _entry('1', text: '😀😀😀', translation: '😀😀😀'),
        );

        expect(entries.single.text, '😀…');
        expect(entries.single.translation, '😀…');
      });

      test('merges a truncated text with the same truncated text', () async {
        final repository = HistoryRepository(store: store, maxTextLength: 5);
        await repository.add(_entry('1', text: 'abcdefgh'));

        final entries = await repository.add(_entry('2', text: 'abcdxyz'));

        expect(entries.map((e) => e.id), ['2']);
      });

      test('evicts the oldest non-favourites beyond maxStoredLength', () async {
        final length = _length(_entry('1'));
        final repository = HistoryRepository(
          store: store,
          maxStoredLength: 3 * length + 5,
        );
        await repository.add(_entry('1', isFavorite: true));
        await repository.add(_entry('2'));
        await repository.add(_entry('3'));

        final entries = await repository.add(_entry('4'));

        expect(entries.map((e) => e.id), ['4', '3', '1']);
        expect(storedIds(), ['4', '3', '1']);
        expect(
          store.values[HistoryRepository.storageKey]!.length,
          lessThanOrEqualTo(3 * length + 5),
        );
      });

      test('never evicts favourites for size', () async {
        final repository = HistoryRepository(store: store, maxStoredLength: 2);
        await repository.add(_entry('1', isFavorite: true));

        final entries = await repository.add(_entry('2', isFavorite: true));

        expect(entries.map((e) => e.id), ['2', '1']);
      });

      test('applies the size limit on load', () async {
        store.values[HistoryRepository.storageKey] = jsonEncode([
          for (var i = 0; i < 4; i++) _entry('$i').toJson(),
        ]);
        final length = _length(_entry('0'));

        final entries = await HistoryRepository(
          store: store,
          maxStoredLength: 2 * length + 4,
        ).load();

        expect(entries.map((e) => e.id), ['0', '1']);
      });

      test('evicts older entries and retries when the quota is '
          'exceeded', () async {
        final length = _length(_entry('1'));
        final store = _QuotaStore(3 * length + 4);
        final repository = HistoryRepository(store: store);
        await repository.add(_entry('1', isFavorite: true));
        await repository.add(_entry('2'));
        await repository.add(_entry('3'));

        final entries = await repository.add(_entry('4'));

        expect(entries.first, _entry('4'));
        expect(entries, contains(_entry('1', isFavorite: true)));
        expect(entries.length, lessThan(4));
        final stored = store.values[HistoryRepository.storageKey]!;
        expect(stored.length, lessThanOrEqualTo(store.limit));
        expect(await HistoryRepository(store: store).load(), entries);
        expect(store.attempts.length, greaterThan(4));
      });

      test('rethrows a quota error when only favourites are left', () async {
        final store = _QuotaStore(10);
        final repository = HistoryRepository(store: store);

        await expectLater(
          repository.add(_entry('1', isFavorite: true)),
          throwsA(isA<_QuotaExceeded>()),
        );
        expect(store.attempts, hasLength(1));
        expect(await repository.exportJson(), '[]');
      });

      test('gives up after a few quota retries', () async {
        final store = _QuotaStore(0);
        final repository = HistoryRepository(store: store);
        store.values[HistoryRepository.storageKey] = jsonEncode([
          for (var i = 0; i < 64; i++) _entry('$i').toJson(),
        ]);

        await expectLater(
          repository.add(_entry('new')),
          throwsA(isA<_QuotaExceeded>()),
        );
        expect(store.attempts, hasLength(5));
        expect(await repository.exportJson(), isNot(contains('"new"')));
      });

      test('truncates imported entries', () async {
        final repository = HistoryRepository(store: store, maxTextLength: 3);

        final entries = await repository.importJson(
          jsonEncode([_entry('1', text: 'abcdef').toJson()]),
        );

        expect(entries.single.text, 'ab…');
      });
    });

    group('restore (regression)', () {
      test('does not merge into a newer entry for the same request', () async {
        final old = _entry('old', text: 'Hello', translation: 'Bonjour');
        final newer = _entry(
          'new',
          text: 'Hello',
          translation: 'Salut',
          minute: 2,
        );
        await repository.add(old);
        await repository.add(_entry('mid', text: 'Bye', minute: 1));
        await repository.add(newer);
        await repository.delete('old');

        final entries = await repository.restore(old);

        expect(entries.map((e) => e.id), ['new', 'mid', 'old']);
        expect(entries.first, newer);
        expect(storedIds(), ['new', 'mid', 'old']);
      });

      test('puts the entry back at its createdAt position', () async {
        await repository.add(_entry('a', minute: 1));
        await repository.add(_entry('b', minute: 2));
        await repository.add(_entry('c', minute: 3));
        await repository.delete('b');

        final entries = await repository.restore(_entry('b', minute: 2));

        expect(entries.map((e) => e.id), ['c', 'b', 'a']);
      });

      test('puts the newest entry back at the front', () async {
        await repository.add(_entry('a', minute: 1));

        final entries = await repository.restore(_entry('b', minute: 2));

        expect(entries.map((e) => e.id), ['b', 'a']);
      });

      test('keeps the favourite flag and replaces the same id', () async {
        await repository.add(_entry('a', minute: 1));
        await repository.add(_entry('b', minute: 2));

        final entries = await repository.restore(
          _entry('a', minute: 1, isFavorite: true),
        );

        expect(entries, [
          _entry('b', minute: 2),
          _entry('a', minute: 1, isFavorite: true),
        ]);
      });

      test('does not evict other entries at the cap', () async {
        final repository = HistoryRepository(store: store, maxEntries: 2);
        await repository.add(_entry('a', minute: 1));
        await repository.add(_entry('b', minute: 2));
        await repository.delete('a');
        await repository.add(_entry('c', minute: 3));

        final entries = await repository.restore(_entry('a', minute: 1));

        expect(entries.map((e) => e.id), ['c', 'b', 'a']);
        expect(storedIds(), ['c', 'b', 'a']);
      });

      test('returns an unmodifiable list', () async {
        final entries = await repository.restore(_entry('a'));

        expect(() => entries.add(_entry('b')), throwsUnsupportedError);
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

      test('does not evict an un-starred entry at the cap, so it can be '
          're-starred (regression)', () async {
        final repository = HistoryRepository(store: store, maxEntries: 2);
        await repository.add(_entry('old', isFavorite: true));
        await repository.add(_entry('n1', minute: 1));
        await repository.add(_entry('n2', minute: 2));

        var entries = await repository.toggleFavorite('old');
        expect(entries.map((e) => e.id), ['n2', 'n1', 'old']);
        expect(storedIds(), ['n2', 'n1', 'old']);

        entries = await repository.toggleFavorite('old');
        expect(entries.last, _entry('old', isFavorite: true));
      });

      test('evicts an un-starred entry beyond the cap on the next '
          'add', () async {
        final repository = HistoryRepository(store: store, maxEntries: 2);
        await repository.add(_entry('old', isFavorite: true));
        await repository.add(_entry('n1', minute: 1));
        await repository.add(_entry('n2', minute: 2));
        await repository.toggleFavorite('old');

        final entries = await repository.add(_entry('n3', minute: 3));

        expect(entries.map((e) => e.id), ['n3', 'n2']);
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

    group('retention', () {
      final now = DateTime(2026, 10, 14, 12);
      const day = Duration(days: 1);

      HistoryEntry aged(String id, Duration age, {bool isFavorite = false}) =>
          HistoryEntry(
            id: id,
            text: 'text $id',
            translation: 'translation $id',
            source: Language.auto,
            target: _french,
            engineId: 'mozhi:google',
            engineName: 'Engine',
            createdAt: now.subtract(age),
            isFavorite: isFavorite,
          );

      late _CountingStore store;
      late HistoryRepository repository;

      void stored(List<HistoryEntry> entries) =>
          store.values[HistoryRepository.storageKey] = jsonEncode([
            for (final entry in entries) entry.toJson(),
          ]);

      List<String> storedIds() => [
        for (final json in jsonDecode(
          store.values[HistoryRepository.storageKey]!,
        ) as List<dynamic>)
          (json as Map<String, dynamic>)['id'] as String,
      ];

      setUp(() {
        store = _CountingStore();
        repository = HistoryRepository(store: store, clock: () => now);
      });

      group('load', () {
        test('drops expired non-favourites and writes the result', () async {
          stored([
            aged('new', const Duration(hours: 2)),
            aged('old', const Duration(days: 2)),
            aged('starred', const Duration(days: 40), isFavorite: true),
          ]);

          final entries = await repository.load(maxAge: day);

          expect(entries.map((e) => e.id), ['new', 'starred']);
          expect(storedIds(), ['new', 'starred']);
          expect(store.writes, 1);
        });

        test('keeps everything without maxAge', () async {
          stored([aged('old', const Duration(days: 400))]);

          final entries = await repository.load();

          expect(entries.map((e) => e.id), ['old']);
          expect(store.writes, 0);
        });

        test('does not write when nothing expired', () async {
          stored([aged('new', const Duration(hours: 23))]);

          final entries = await repository.load(maxAge: day);

          expect(entries.map((e) => e.id), ['new']);
          expect(store.writes, 0);
        });

        test('keeps an entry created exactly maxAge ago', () async {
          stored([aged('edge', day)]);

          final entries = await repository.load(maxAge: day);

          expect(entries.map((e) => e.id), ['edge']);
        });

        test('keeps the pruned list when writing it back fails', () async {
          final failing = _FailingWriteStore();
          failing.values[HistoryRepository.storageKey] = jsonEncode([
            aged('new', Duration.zero).toJson(),
            aged('old', const Duration(days: 3)).toJson(),
          ]);
          final repository = HistoryRepository(
            store: failing,
            clock: () => now,
          );

          final entries = await repository.load(maxAge: day);

          expect(entries.map((e) => e.id), ['new']);
          expect(failing.attempts, 1);
          expect((await repository.exportJson()).contains('"old"'), isFalse);
        });
      });

      group('add', () {
        test('drops expired non-favourites', () async {
          stored([
            aged('old', const Duration(days: 8)),
            aged('week', const Duration(days: 6)),
            aged('starred', const Duration(days: 8), isFavorite: true),
          ]);

          final entries = await repository.add(
            aged('new', Duration.zero),
            maxAge: const Duration(days: 7),
          );

          expect(entries.map((e) => e.id), ['new', 'week', 'starred']);
          expect(storedIds(), ['new', 'week', 'starred']);
        });

        test('keeps everything without maxAge', () async {
          stored([aged('old', const Duration(days: 400))]);

          final entries = await repository.add(aged('new', Duration.zero));

          expect(entries.map((e) => e.id), ['new', 'old']);
        });
      });

      test('importJson drops expired non-favourites', () async {
        final json = jsonEncode([
          aged('new', const Duration(hours: 1)).toJson(),
          aged('old', const Duration(days: 2)).toJson(),
          aged('starred', const Duration(days: 2), isFavorite: true).toJson(),
        ]);

        final entries = await repository.importJson(json, maxAge: day);

        expect(entries.map((e) => e.id), ['new', 'starred']);
      });

      group('prune', () {
        test('deletes expired non-favourites and persists', () async {
          stored([
            aged('new', const Duration(days: 29)),
            aged('old', const Duration(days: 31)),
            aged('starred', const Duration(days: 365), isFavorite: true),
          ]);

          final entries = await repository.prune(const Duration(days: 30));

          expect(entries.map((e) => e.id), ['new', 'starred']);
          expect(storedIds(), ['new', 'starred']);
          expect(await repository.load(), entries);
        });

        test('keeps everything for null and does not write', () async {
          stored([aged('old', const Duration(days: 400))]);

          final entries = await repository.prune(null);

          expect(entries.map((e) => e.id), ['old']);
          expect(store.writes, 0);
        });

        test('does not write when nothing expired', () async {
          await repository.add(aged('new', Duration.zero));

          final entries = await repository.prune(day);

          expect(entries.map((e) => e.id), ['new']);
          expect(store.writes, 1);
        });

        test('returns an unmodifiable list', () async {
          stored([aged('old', const Duration(days: 2))]);

          final entries = await repository.prune(day);

          expect(entries, isEmpty);
          expect(() => entries.add(aged('x', day)), throwsUnsupportedError);
        });

        test('propagates storage errors and keeps the history', () async {
          final failing = _FailingWriteStore();
          failing.values[HistoryRepository.storageKey] = jsonEncode([
            aged('old', const Duration(days: 2)).toJson(),
          ]);
          final repository = HistoryRepository(
            store: failing,
            clock: () => now,
          );

          await expectLater(repository.prune(day), throwsStateError);
          expect((await repository.load()).map((e) => e.id), ['old']);
        });
      });

      test('uses the current time by default', () async {
        final repository = HistoryRepository(store: MemoryStore());
        final entry = aged('x', Duration.zero);

        final entries = await repository.add(
          HistoryEntry(
            id: 'recent',
            text: entry.text,
            translation: entry.translation,
            source: entry.source,
            target: entry.target,
            engineId: entry.engineId,
            engineName: entry.engineName,
            createdAt: DateTime.now().subtract(const Duration(minutes: 1)),
          ),
          maxAge: day,
        );
        final pruned = await repository.prune(const Duration(seconds: 30));

        expect(entries.map((e) => e.id), ['recent']);
        expect(pruned, isEmpty);
      });
    });
  });
}
