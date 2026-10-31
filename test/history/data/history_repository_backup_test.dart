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

  group('Clear history record', () {
    /// The record stored in [store] (decrypted).
    Future<Object?> storedCleared([MemoryStore? from]) async {
      final raw = (from ?? store).values[HistoryRepository.clearedStorageKey];
      if (raw == null) return null;
      return jsonDecode(
        await const HistoryCipher().decrypt(
          raw,
          base64Decode(keys.values[HistoryRepository.keyStorageKey]!),
          aad: HistoryRepository.clearedAssociatedData,
        ),
      );
    }

    test('clear records when, encrypted, and the later of each kind', () async {
      final repository = build();
      await repository.add(_entry('1'));
      expect((await repository.backupData()).cleared, HistoryCleared.none);

      await repository.clear(keepFavorites: true);
      expect(await storedCleared(), {
        'nonFavorites': now.toUtc().toIso8601String(),
      });
      expect(
        store.values[HistoryRepository.clearedStorageKey],
        startsWith(HistoryCipher.prefix),
      );

      final first = now;
      now = now.add(const Duration(hours: 1));
      await repository.clear();
      final cleared = HistoryCleared(all: now, nonFavorites: first);
      expect((await repository.backupData()).cleared, cleared);
      // Read back by a new repository.
      expect((await build().backupData()).cleared, cleared);
    });

    test('a sync merge drops what a clear here covers and leaves tombstones '
        'from its time', () async {
      final repository = build();
      await repository.clear(keepFavorites: true);
      final clearedAt = now;
      now = now.add(const Duration(days: 1));

      final entries = await repository.mergeBackup([
        _entry('old'),
        _entry('starred', minute: 1, isFavorite: true),
        _entry('edited after', minute: 2, updatedAt: now),
        _entry(
          'starred then un-starred',
          minute: 3,
          updatedAt: clearedAt.subtract(const Duration(minutes: 1)),
        ),
        HistoryEntry(
          id: 'new',
          text: 'text',
          translation: 'translation',
          source: _english,
          target: _french,
          engineId: 'mozhi:google',
          engineName: 'Engine',
          createdAt: now,
        ),
      ], sync: const HistorySyncMerge());

      expect(entries.map((e) => e.id), ['new', 'edited after', 'starred']);
      expect(await storedTombstones(), {
        'old': clearedAt.millisecondsSinceEpoch,
        'starred then un-starred': clearedAt.millisecondsSinceEpoch,
      });

      // A clear of everything in the file takes the favourites too.
      await repository.mergeBackup(
        const [],
        sync: HistorySyncMerge(cleared: HistoryCleared(all: clearedAt)),
      );
      final data = await repository.backupData();
      expect(data.entries.map((e) => e.id), ['new', 'edited after']);
      expect(
        data.cleared,
        HistoryCleared(all: clearedAt, nonFavorites: clearedAt),
      );
    });

    test('a member of the folder applies its clear to its own entries, and '
        'keeps it', () async {
      final repository = build();
      await repository.add(_entry('mine'));
      await repository.add(_entry('starred', minute: 1, isFavorite: true));

      final joinedAt = now.subtract(const Duration(days: 1));
      await repository.mergeBackup(
        const [],
        sync: HistorySyncMerge(
          cleared: HistoryCleared(nonFavorites: now),
          joinedAt: joinedAt,
        ),
      );

      expect((await repository.backupData()).entries.map((e) => e.id), [
        'starred',
      ]);
      expect(await storedCleared(), {
        'nonFavorites': now.toUtc().toIso8601String(),
        'joinedAt': joinedAt.toUtc().toIso8601String(),
      });
      expect((await storedTombstones()).keys, ['mine']);
    });

    test('a device that joined after a clear keeps its own entries, and '
        'takes none of the file covers', () async {
      final repository = build();
      await repository.add(_entry('mine'));
      final clearedAt = now.subtract(const Duration(days: 2));
      now = now.add(const Duration(minutes: 5));
      final joinedAt = now.subtract(const Duration(days: 1));
      final clear = HistorySyncMerge(
        cleared: HistoryCleared(all: clearedAt),
        joinedAt: joinedAt,
      );

      final entries = await repository.mergeBackup(
        [_entry('theirs', minute: 1)],
        tombstones: [
          // Left for it by a device that cleared before it knew this one.
          HistoryTombstone(id: 'mine', deletedAt: clearedAt.toUtc()),
        ],
        sync: clear,
      );

      // Counts as changed when it joined, so that no clear before takes it.
      expect(entries.single.id, 'mine');
      expect(entries.single.updatedAt, joinedAt);
      expect(await storedTombstones(), {
        'theirs': clearedAt.millisecondsSinceEpoch,
      });
      expect(await storedCleared(), {
        'all': clearedAt.toUtc().toIso8601String(),
        'joinedAt': joinedAt.toUtc().toIso8601String(),
      });

      // Only once: what came from the file since is not its own.
      final later = await repository.mergeBackup([
        _entry('in the file', minute: 2),
      ], sync: HistorySyncMerge(joinedAt: joinedAt));
      expect(later.map((e) => e.id), ['in the file', 'mine']);
      // (A read back repository knows it stamped already.)
      final fresh = build();
      final cleared = await fresh.mergeBackup(const [], sync: clear);
      expect(cleared.map((e) => e.id), ['mine']);

      // A later tombstone (a delete) still takes it.
      final deleted = await fresh.mergeBackup(
        const [],
        tombstones: [HistoryTombstone(id: 'mine', deletedAt: now.toUtc())],
        sync: clear,
      );
      expect(deleted, isEmpty);
    });

    test('a clear made here before joining never takes the file', () async {
      final repository = build();
      await repository.clear();
      final clearedAt = now;
      now = now.add(const Duration(days: 1));

      final entries = await repository.mergeBackup([
        _entry('theirs'),
      ], sync: HistorySyncMerge(joinedAt: now));

      expect(entries.map((e) => e.id), ['theirs']);
      // Still this device's own record (backups, and what it imports).
      expect(
        (await repository.backupData()).cleared,
        HistoryCleared(all: clearedAt),
      );
    });

    test("a backup's clear never takes this device's entries; what it "
        "brings in that this device's clear covers stays", () async {
      final repository = build();
      await repository.add(_entry('cleared here'));
      await repository.clear();
      final clearedAt = now;
      now = now.add(const Duration(minutes: 1));
      await repository.add(_entry('mine', minute: 1, updatedAt: now));

      final entries = await repository.mergeBackup([
        _entry('cleared here'),
        _entry('theirs', minute: 2),
      ]);
      // The other side's record is never asked for.
      expect(entries.map((e) => e.id), ['theirs', 'mine']);
      expect(entries.first.updatedAt, now);
      expect(
        (await repository.backupData()).cleared,
        HistoryCleared(all: clearedAt),
      );

      // Neither does a later sync merge take it.
      final synced = await repository.mergeBackup(
        const [],
        sync: HistorySyncMerge(cleared: HistoryCleared(all: clearedAt)),
      );
      expect(synced.map((e) => e.id), ['theirs', 'mine']);
    });

    test('a clear more than a day ahead of the clock is left out, one ahead '
        'by less counts as now', () async {
      final repository = build();
      await repository.add(_entry('1'));

      await repository.mergeBackup(
        const [],
        sync: HistorySyncMerge(
          cleared: HistoryCleared(all: now.add(const Duration(days: 400))),
        ),
      );
      expect((await repository.backupData()).entries, hasLength(1));
      expect((await repository.backupData()).cleared, HistoryCleared.none);

      await repository.mergeBackup(
        const [],
        sync: HistorySyncMerge(
          cleared: HistoryCleared(all: now.add(const Duration(hours: 3))),
        ),
      );
      expect((await repository.backupData()).entries, isEmpty);
      expect((await repository.backupData()).cleared, HistoryCleared(all: now));
    });

    test("replaceAll keeps this device's record and the backup's entries it "
        'covers', () async {
      final repository = build();
      await repository.clear();
      final clearedAt = now;
      now = now.add(const Duration(hours: 1));

      final entries = await repository.replaceAll([_entry('1')]);
      expect(entries.single.updatedAt, now);
      expect(
        (await repository.backupData()).cleared,
        HistoryCleared(all: clearedAt),
      );
      final synced = await repository.mergeBackup(
        const [],
        sync: const HistorySyncMerge(),
      );
      expect(synced.single.id, '1');
    });

    test('an entry brought back although a clear covers it counts as changed '
        'now', () async {
      final repository = build();
      await repository.clear();
      final clearedAt = now;

      // E.g. a translation made just before the clear, saved after it (in
      // the same millisecond).
      final added = await repository.add(_entry('added'));
      final stamp = clearedAt.toUtc().add(const Duration(milliseconds: 1));
      expect(added.single.updatedAt, stamp);
      now = now.add(const Duration(minutes: 1));
      final restored = await repository.restore(_entry('restored', minute: 1));
      expect(restored.first.updatedAt, now);
      final imported = await repository.importJson(
        jsonEncode([_entry('imported', minute: 2).toJson()]),
      );
      expect(imported.entries.first.updatedAt, now);

      // So the clear doesn't take them again.
      final merged = await repository.mergeBackup(
        const [],
        sync: const HistorySyncMerge(),
      );
      expect(merged.map((e) => e.id), ['imported', 'restored', 'added']);
    });

    test('a failing write keeps the record and retries later', () async {
      final failing = _FailingKeyStore(HistoryRepository.clearedStorageKey);
      final repository = build(store_: failing);
      await repository.add(_entry('1'));

      expect(await repository.clear(), isEmpty);
      expect(
        failing.values,
        isNot(contains(HistoryRepository.clearedStorageKey)),
      );
      expect((await repository.backupData()).cleared, HistoryCleared(all: now));

      failing.limit = 1 << 20;
      await repository.mergeBackup(const [], sync: const HistorySyncMerge());
      expect(await storedCleared(failing), {
        'all': now.toUtc().toIso8601String(),
      });
    });

    test('a damaged record is ignored', () async {
      final repository = build();
      await repository.add(_entry('1'));
      store.values[HistoryRepository.clearedStorageKey] = 'damaged';

      expect((await repository.backupData()).cleared, HistoryCleared.none);
    });

    test('is deleted by deleteAll and discardUnreadable, and counts in '
        'storedLength', () async {
      final repository = build();
      await repository.add(_entry('1'));
      await repository.clear();
      expect(
        await repository.storedLength(),
        store.values[HistoryRepository.storageKey]!.length +
            store.values[HistoryRepository.tombstonesStorageKey]!.length +
            store.values[HistoryRepository.clearedStorageKey]!.length,
      );

      await repository.deleteAll();
      expect(store.values, isEmpty);
      expect((await repository.backupData()).cleared, HistoryCleared.none);

      await repository.add(_entry('2'));
      await repository.clear();
      keys.values.clear();
      final unreadable = build();
      await expectLater(
        unreadable.load(),
        throwsA(isA<HistoryUnreadableException>()),
      );
      await unreadable.discardUnreadable();
      expect(
        store.values,
        isNot(contains(HistoryRepository.clearedStorageKey)),
      );
      expect((await unreadable.backupData()).cleared, HistoryCleared.none);
    });
  });

  group('HistoryCleared', () {
    test('parses leniently and writes only what it records', () {
      final at = DateTime.utc(2026, 10, 20);
      expect(HistoryCleared.fromJson(null), HistoryCleared.none);
      expect(HistoryCleared.fromJson('x'), HistoryCleared.none);
      expect(
        HistoryCleared.fromJson(const {'all': 'yesterday', 'nonFavorites': 7}),
        HistoryCleared.none,
      );
      expect(
        HistoryCleared.fromJson(HistoryCleared(all: at).toJson()),
        HistoryCleared(all: at),
      );
      expect(HistoryCleared.none.toJson(), isEmpty);
      expect(HistoryCleared.none.isEmpty, isTrue);
      expect(
        HistoryCleared(all: at).union(HistoryCleared(nonFavorites: at)),
        HistoryCleared(all: at, nonFavorites: at),
      );
    });

    test('splits at a join time', () {
      final early = DateTime.utc(2026, 10);
      final late = DateTime.utc(2026, 10, 20);
      final both = HistoryCleared(all: early, nonFavorites: late);
      final joined = DateTime.utc(2026, 10, 10);
      expect(both.since(null), both);
      expect(both.before(null), HistoryCleared.none);
      expect(both.since(joined), HistoryCleared(nonFavorites: late));
      expect(both.before(joined), HistoryCleared(all: early));
      expect(both.since(early), both);
      expect(
        both.isClearTime(early.add(const Duration(microseconds: 5))),
        isTrue,
      );
      expect(both.isClearTime(joined), isFalse);
      expect(
        HistorySyncMerge(joinedAt: joined),
        HistorySyncMerge(joinedAt: joined),
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
