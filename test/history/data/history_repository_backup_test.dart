import 'dart:convert';

import 'package:flutter_test/flutter_test.dart';
import 'package:mozhi/core/key_value_store.dart';
import 'package:mozhi/history/data/history_repository.dart';
import 'package:mozhi/history/models/history_entry.dart';
import 'package:translation_repository/translation_repository.dart';

const _english = Language(code: 'en', name: 'English');
const _french = Language(code: 'fr', name: 'French');

HistoryEntry _entry(
  String id, {
  int minute = 0,
  bool isFavorite = false,
  DateTime? updatedAt,
  String? translation,
}) => HistoryEntry(
  id: id,
  text: 'text $id',
  translation: translation ?? 'translation $id',
  source: _english,
  target: _french,
  engineId: 'mozhi:google',
  engineName: 'Engine',
  createdAt: DateTime(2026, 10, 13, 12, minute),
  isFavorite: isFavorite,
  updatedAt: updatedAt,
);

HistoryEntry _lookUp(
  String id, {
  String word = 'Weg',
  int minute = 0,
  bool isFavorite = false,
}) => HistoryEntry(
  id: id,
  text: word,
  translation: 'way',
  source: const Language(code: 'de', name: 'German'),
  target: _english,
  engineId: 'ai:p',
  engineName: 'AI',
  createdAt: DateTime(2026, 10, 13, 12, minute),
  isFavorite: isFavorite,
  kind: HistoryEntryKind.dictionary,
);

/// A store that fails every write of [failing].
class _FailingKeyStore extends MemoryStore {
  new(this.failing, {this.quota = false});

  final String failing;
  final bool quota;
  int attempts = 0;
  int? limit;

  @override
  Future<void> write(String key, String value) async {
    if (key == failing) {
      attempts++;
      if (limit != null && value.length <= limit!) {
        return await super.write(key, value);
      }
      throw StateError(quota ? 'QuotaExceededError' : 'disk full');
    }
    return await super.write(key, value);
  }
}

void main() {
  var now = DateTime(2026, 10, 20, 9);
  late MemoryStore store;
  late MemoryStore keys;

  HistoryRepository build({
    KeyValueStore? store_,
    int maxEntries = 1000,
    int maxTombstones = 10000,
    Duration tombstoneMaxAge = const Duration(days: 180),
  }) => HistoryRepository(
    store: store_ ?? store,
    keyStore: keys,
    maxEntries: maxEntries,
    maxTombstones: maxTombstones,
    tombstoneMaxAge: tombstoneMaxAge,
    clock: () => now,
  );

  /// The tombstones stored in [store] (decrypted).
  Future<Map<String, int>> storedTombstones([MemoryStore? from]) async {
    final raw = (from ?? store).values[HistoryRepository.tombstonesStorageKey];
    if (raw == null) return {};
    final json = await const HistoryCipher().decrypt(
      raw,
      base64Decode(keys.values[HistoryRepository.keyStorageKey]!),
      aad: HistoryRepository.tombstonesAssociatedData,
    );
    return Map<String, int>.from(jsonDecode(json) as Map);
  }

  setUp(() {
    now = DateTime(2026, 10, 20, 9);
    store = MemoryStore();
    keys = MemoryStore();
  });

  group('tombstones', () {
    test('delete leaves one, encrypted', () async {
      final repository = build();
      await repository.add(_entry('1'));
      await repository.add(_entry('2', minute: 1));

      await repository.delete('1');

      expect(await storedTombstones(), {'1': now.millisecondsSinceEpoch});
      final raw = store.values[HistoryRepository.tombstonesStorageKey]!;
      expect(raw, startsWith(HistoryCipher.prefix));
      // Not readable as the history: another associated data.
      await expectLater(
        const HistoryCipher().decrypt(
          raw,
          base64Decode(keys.values[HistoryRepository.keyStorageKey]!),
        ),
        throwsA(isA<HistoryCipherException>()),
      );
      final data = await build().backupData();
      expect(data.tombstones, [
        HistoryTombstone(id: '1', deletedAt: now.toUtc()),
      ]);
      expect(data.entries.map((e) => e.id), ['2']);
    });

    test('clear leaves one per entry it deletes', () async {
      final repository = build();
      await repository.add(_entry('1', isFavorite: true));
      await repository.add(_entry('2', minute: 1));
      await repository.add(_entry('3', minute: 2));

      await repository.clear(keepFavorites: true);
      expect((await storedTombstones()).keys, unorderedEquals(['2', '3']));

      await repository.clear();
      expect((await storedTombstones()).keys, unorderedEquals(['1', '2', '3']));
    });

    test('un-starring an entry kept only as a favourite leaves one', () async {
      final repository = build();
      await repository.add(
        _entry('1', isFavorite: true).copyWith(favoriteOnly: true),
      );

      await repository.toggleFavorite('1');

      expect((await storedTombstones()).keys, ['1']);
    });

    test('a translation replacing the newest with another id leaves one '
        'for the replaced id', () async {
      final repository = build();
      await repository.add(_entry('1'));
      await repository.add(
        _entry('2').copyWith(text: 'text 1', translation: 'new'),
      );

      expect((await storedTombstones()).keys, ['1']);
    });

    test('caps and retention leave none', () async {
      final repository = build(maxEntries: 1);
      await repository.add(_entry('1'));
      await repository.add(_entry('2', minute: 1));
      expect((await repository.backupData()).entries.map((e) => e.id), ['2']);

      await repository.prune(const Duration(minutes: 1));

      expect(await repository.load(), isEmpty);
      expect(
        store.values,
        isNot(contains(HistoryRepository.tombstonesStorageKey)),
      );
    });

    test('an entry that comes back drops its tombstone', () async {
      final repository = build();
      final entry = _entry('1');
      await repository.add(entry);
      await repository.delete('1');

      await repository.restore(entry);

      expect(await storedTombstones(), isEmpty);
      expect(
        store.values,
        isNot(contains(HistoryRepository.tombstonesStorageKey)),
      );
    });

    test('older than tombstoneMaxAge are dropped', () async {
      final repository = build(tombstoneMaxAge: const Duration(days: 10));
      await repository.add(_entry('1'));
      await repository.add(_entry('2', minute: 1));
      await repository.delete('1');
      now = now.add(const Duration(days: 11));

      await repository.delete('2');

      expect((await storedTombstones()).keys, ['2']);
    });

    test('at most maxTombstones, the newest', () async {
      final repository = build(maxTombstones: 2);
      for (var i = 0; i < 3; i++) {
        await repository.add(_entry('$i', minute: i));
      }
      for (var i = 0; i < 3; i++) {
        now = now.add(const Duration(minutes: 1));
        await repository.delete('$i');
      }

      expect((await storedTombstones()).keys, unorderedEquals(['1', '2']));
    });

    test('are read back by a new repository', () async {
      await build().add(_entry('1'));
      await build().delete('1');

      final data = await build().backupData();

      expect(data.tombstones.single.id, '1');
    });

    test('damaged ones are ignored and written anew', () async {
      final repository = build();
      await repository.add(_entry('1'));
      await repository.add(_entry('2', minute: 1));
      store.values[HistoryRepository.tombstonesStorageKey] = 'garbage';

      final fresh = build();
      expect((await fresh.backupData()).tombstones, isEmpty);
      await fresh.delete('2');

      expect((await storedTombstones()).keys, ['2']);
    });

    test('a failing write keeps the history change and retries '
        'later', () async {
      final failing = _FailingKeyStore(HistoryRepository.tombstonesStorageKey);
      final repository = build(store_: failing);
      await repository.add(_entry('1'));
      await repository.add(_entry('2', minute: 1));

      expect((await repository.delete('1')).map((e) => e.id), ['2']);
      expect(
        failing.values,
        isNot(contains(HistoryRepository.tombstonesStorageKey)),
      );
      expect((await repository.backupData()).tombstones.single.id, '1');

      // The next change writes them.
      failing.limit = 1 << 20;
      await repository.add(_entry('3', minute: 2));
      expect((await storedTombstones(failing)).keys, ['1']);
    });

    test('a full quota drops the older half', () async {
      final failing = _FailingKeyStore(
        HistoryRepository.tombstonesStorageKey,
        quota: true,
      );
      final repository = build(store_: failing);
      for (var i = 0; i < 8; i++) {
        await repository.add(_entry('$i', minute: i));
      }
      failing.limit = 0;
      for (var i = 0; i < 4; i++) {
        now = now.add(const Duration(minutes: 1));
        await repository.delete('$i');
      }
      // Room for about two.
      final two = HistoryCipher.encryptedLength(
        jsonEncode({'0': 0, '1': 0}).length + 30,
      );
      failing.limit = two;
      now = now.add(const Duration(minutes: 1));
      await repository.delete('4');

      final kept = await storedTombstones(failing);
      expect(kept.length, lessThan(5));
      expect(kept.keys, contains('4'));
    });

    test('are deleted by deleteAll and discardUnreadable', () async {
      final repository = build();
      await repository.add(_entry('1'));
      await repository.delete('1');

      await repository.deleteAll();
      expect(store.values, isEmpty);
      expect((await repository.backupData()).tombstones, isEmpty);

      await repository.add(_entry('2'));
      await repository.delete('2');
      keys.values.clear();
      final unreadable = build();
      await expectLater(
        unreadable.load(),
        throwsA(isA<HistoryUnreadableException>()),
      );
      await unreadable.discardUnreadable();
      expect(
        store.values,
        isNot(contains(HistoryRepository.tombstonesStorageKey)),
      );
      expect((await unreadable.backupData()).tombstones, isEmpty);
    });

    test('count in storedLength', () async {
      final repository = build();
      await repository.add(_entry('1'));
      await repository.add(_entry('2', minute: 1));
      await repository.delete('1');

      expect(
        await repository.storedLength(),
        store.values[HistoryRepository.storageKey]!.length +
            store.values[HistoryRepository.tombstonesStorageKey]!.length,
      );
    });
  });

  group('updatedAt', () {
    test('is stamped when an entry is starred or un-starred', () async {
      final repository = build();
      await repository.add(_entry('1'));
      expect((await repository.backupData()).entries.single.updatedAt, isNull);

      var entries = await repository.toggleFavorite('1');
      expect(entries.single.updatedAt, now);
      now = now.add(const Duration(hours: 1));
      entries = await repository.toggleFavorite('1');
      expect(entries.single.updatedAt, now);

      // Stored and read back.
      expect((await build().load()).single.updatedAt, now);
    });

    test('is stamped by restoreFavorite', () async {
      final repository = build();
      final starred = _entry('1', isFavorite: true);
      await repository.add(starred);
      await repository.toggleFavorite('1');
      now = now.add(const Duration(minutes: 5));

      final entries = await repository.restoreFavorite(starred);

      expect(entries.single.updatedAt, now);
    });

    test('is stamped when an import stars an existing look-up', () async {
      final repository = build();
      await repository.add(_lookUp('1'));

      final imported = await repository.importJson(
        jsonEncode([_lookUp('2', isFavorite: true).toJson()]),
      );

      expect(imported.entries.single.isFavorite, isTrue);
      expect(imported.entries.single.updatedAt, now);
    });
  });

  group('replaceAll', () {
    test('makes the backup the history, newest first', () async {
      final repository = build();
      await repository.add(_entry('local'));
      await repository.delete('local');
      await repository.add(_entry('other'));

      final entries = await repository.replaceAll(
        [_entry('a', minute: 1), _entry('b', minute: 3), _entry('a')],
        tombstones: [
          HistoryTombstone(id: 'gone', deletedAt: now.toUtc()),
          // Present in the backup: dropped.
          HistoryTombstone(id: 'b', deletedAt: now.toUtc()),
        ],
      );

      expect(entries.map((e) => e.id), ['b', 'a']);
      expect(entries.last.createdAt.minute, 1);
      expect((await build().load()).map((e) => e.id), ['b', 'a']);
      expect((await storedTombstones()).keys, ['gone']);
    });

    test('caps and truncates', () async {
      final repository = HistoryRepository(
        store: store,
        keyStore: keys,
        maxEntries: 1,
        maxTextLength: 5,
        clock: () => now,
      );

      final entries = await repository.replaceAll([
        _entry('1'),
        _entry('2', minute: 1),
        _entry('3', isFavorite: true),
      ]);

      expect(entries.map((e) => e.id), ['2', '3']);
      expect(entries.first.text, 'text…');
    });

    test('merges look-ups of the same word', () async {
      final entries = await build().replaceAll([
        _lookUp('1', isFavorite: true),
        _lookUp('2', minute: 5),
      ]);

      expect(entries.single.id, '2');
      expect(entries.single.isFavorite, isTrue);
      expect((await storedTombstones()).keys, ['1']);
    });

    test('with nothing empties the history', () async {
      final repository = build();
      await repository.add(_entry('1'));

      expect(await repository.replaceAll(const []), isEmpty);
      expect(await build().load(), isEmpty);
      expect(
        store.values,
        isNot(contains(HistoryRepository.tombstonesStorageKey)),
      );
    });

    test('refuses to overwrite a history that cannot be read', () async {
      await build().add(_entry('1'));
      keys.values.clear();

      await expectLater(
        build().replaceAll([_entry('2')]),
        throwsA(isA<HistoryUnreadableException>()),
      );
    });
  });

  group('mergeBackup', () {
    late HistoryRepository repository;

    setUp(() => repository = build());

    test('keeps entries only on either side', () async {
      await repository.add(_entry('local'));

      final entries = await repository.mergeBackup([
        _entry('remote', minute: 5),
      ]);

      expect(entries.map((e) => e.id), ['remote', 'local']);
    });

    test('keeps the newer copy of an entry', () async {
      await repository.add(_entry('1'));
      await repository.add(_entry('2', minute: 1));
      await repository.toggleFavorite('2');

      final entries = await repository.mergeBackup([
        // Starred on the other device after it was made here.
        _entry('1', isFavorite: true, updatedAt: now),
        // Older than this device's star.
        _entry('2', updatedAt: now.subtract(const Duration(days: 1))),
      ]);

      expect(entries.map((e) => (e.id, e.isFavorite)), [
        ('2', true),
        ('1', true),
      ]);
    });

    test('keeps this copy on a tie', () async {
      await repository.add(_entry('1', translation: 'mine'));

      final entries = await repository.mergeBackup([
        _entry('1', translation: 'theirs'),
      ]);

      expect(entries.single.translation, 'mine');
    });

    test('a tombstone from the backup deletes older entries', () async {
      await repository.add(_entry('old'));
      await repository.add(_entry('changed', minute: 1));
      now = now.add(const Duration(hours: 2));
      await repository.toggleFavorite('changed');

      final entries = await repository.mergeBackup(
        const [],
        tombstones: [
          HistoryTombstone(
            id: 'old',
            deletedAt: now.subtract(const Duration(hours: 1)),
          ),
          // Deleted there before it was starred here: it stays.
          HistoryTombstone(
            id: 'changed',
            deletedAt: now.subtract(const Duration(hours: 1)),
          ),
        ],
      );

      expect(entries.map((e) => e.id), ['changed']);
      expect((await storedTombstones()).keys, ['old']);
    });

    test('a tombstone here keeps a deleted entry from coming back', () async {
      await repository.add(_entry('1'));
      await repository.delete('1');

      final entries = await repository.mergeBackup([_entry('1')]);

      expect(entries, isEmpty);
      expect((await storedTombstones()).keys, ['1']);
    });

    test('keeps the later of two tombstones', () async {
      await repository.add(_entry('1'));
      await repository.delete('1');
      final later = now.add(const Duration(days: 1));
      final earlier = now.subtract(const Duration(days: 1));

      await repository.mergeBackup(
        const [],
        tombstones: [HistoryTombstone(id: '1', deletedAt: later)],
      );
      expect(
        (await repository.backupData()).tombstones.single.deletedAt,
        later.toUtc(),
      );
      await repository.mergeBackup(
        const [],
        tombstones: [HistoryTombstone(id: '1', deletedAt: earlier)],
      );
      expect(
        (await repository.backupData()).tombstones.single.deletedAt,
        later.toUtc(),
      );
    });

    test('merges look-ups of the same word into the newest', () async {
      await repository.add(_lookUp('mine', isFavorite: true));

      final entries = await repository.mergeBackup([
        _lookUp('theirs', minute: 10),
      ]);

      expect(entries.single.id, 'theirs');
      expect(entries.single.isFavorite, isTrue);
      expect(entries.single.updatedAt, now);
      expect((await storedTombstones()).keys, ['mine']);
    });

    test('is written and capped', () async {
      final repository = build(maxEntries: 2);
      await repository.add(_entry('1'));

      final entries = await repository.mergeBackup([
        _entry('2', minute: 1),
        _entry('3', minute: 2),
        _entry('fav', isFavorite: true),
      ]);

      expect(entries.map((e) => e.id), ['3', '2', 'fav']);
      expect((await build().load()).map((e) => e.id), ['3', '2', 'fav']);
    });

    test('merging the same backup twice changes nothing', () async {
      await repository.add(_entry('1'));
      final backup = [_entry('2', minute: 1), _entry('1')];

      final first = await repository.mergeBackup(backup);
      final second = await repository.mergeBackup(backup);

      expect(second, first);
    });
  });

  group('mergeBackup with a retention', () {
    late HistoryRepository repository;

    /// A non-favourite created [ago] before now.
    HistoryEntry recent(String id, Duration ago, {bool isFavorite = false}) =>
        HistoryEntry(
          id: id,
          text: 'text $id',
          translation: 'translation $id',
          source: _english,
          target: _french,
          engineId: 'mozhi:google',
          engineName: 'Engine',
          createdAt: now.subtract(ago),
          isFavorite: isFavorite,
        );

    setUp(() => repository = build());

    test('leaves out what it would delete, from both sides, without '
        'tombstones', () async {
      await repository.add(_entry('old here'));
      await repository.add(_entry('old favourite here', isFavorite: true));
      await repository.add(recent('new here', const Duration(hours: 1)));

      final entries = await repository.mergeBackup([
        _entry('old there', minute: 1),
        _entry('old favourite there', minute: 1, isFavorite: true),
        recent('new there', const Duration(hours: 2)),
      ], maxAge: const Duration(days: 1));

      expect(entries.map((e) => e.id), [
        'new here',
        'new there',
        'old favourite there',
        'old favourite here',
      ]);
      expect(await storedTombstones(), isEmpty);
      expect((await build().load()).map((e) => e.id), [
        'new here',
        'new there',
        'old favourite there',
        'old favourite here',
      ]);
    });

    test('never brings back what the retention deleted here', () async {
      final backup = [
        _entry('expired'),
        recent('kept', const Duration(minutes: 5)),
      ];
      await repository.mergeBackup(backup);
      // "Delete history automatically" deletes it here.
      await repository.prune(const Duration(days: 1));

      // The next sync brings the same copy again.
      final entries = await repository.mergeBackup(
        backup,
        maxAge: const Duration(days: 1),
      );

      expect(entries.map((e) => e.id), ['kept']);
      // What this device uploads next leaves it out too.
      expect((await repository.backupData()).entries.map((e) => e.id), [
        'kept',
      ]);
      expect(await storedTombstones(), isEmpty);
    });

    test('caps keep the newest', () async {
      final repository = build(maxEntries: 2);
      await repository.add(recent('oldest kept out', const Duration(hours: 3)));

      final entries = await repository.mergeBackup([
        recent('newer', const Duration(hours: 2)),
        recent('newest', const Duration(hours: 1)),
        _entry('expired'),
      ], maxAge: const Duration(days: 1));

      expect(entries.map((e) => e.id), ['newest', 'newer']);
      expect(await storedTombstones(), isEmpty);
    });
  });
}
