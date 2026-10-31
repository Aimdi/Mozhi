import 'dart:convert';

import 'package:flutter_test/flutter_test.dart';
import 'package:mozhi/backup/data/backup_registry.dart';
import 'package:mozhi/backup/sections/history_backup_section.dart';
import 'package:mozhi/core/key_value_store.dart';
import 'package:mozhi/history/data/history_repository.dart';
import 'package:mozhi/history/models/history_entry.dart';
import 'package:translation_repository/translation_repository.dart';

HistoryEntry _entry(String id, {int minute = 0, bool isFavorite = false}) =>
    HistoryEntry(
      id: id,
      text: 'text $id',
      translation: 'translation $id',
      source: const Language(code: 'en', name: 'English'),
      target: const Language(code: 'fr', name: 'French'),
      engineId: 'mozhi:google',
      engineName: 'Engine',
      createdAt: DateTime(2026, 10, 13, 12, minute),
      isFavorite: isFavorite,
    );

Object? _throughJson(Object? data) => jsonDecode(jsonEncode(data));

void main() {
  final now = DateTime(2026, 10, 20, 9);
  late HistoryRepository repository;
  late HistoryBackupSection section;

  setUp(() {
    repository = HistoryRepository(
      store: MemoryStore(),
      keyStore: MemoryStore(),
      clock: () => now,
    );
    section = HistoryBackupSection(repository);
  });

  test('has its id and version', () {
    expect(section.id, 'history');
    expect(section.version, 1);
  });

  test('exports the entries and tombstones', () async {
    await repository.add(_entry('1', isFavorite: true));
    await repository.add(_entry('2', minute: 1));
    await repository.add(_entry('3', minute: 2));
    await repository.delete('3');

    final data = _throughJson(await section.export(includeSecrets: true));

    expect(data, {
      'entries': [
        _entry('2', minute: 1).toJson(),
        _entry('1').toJson()..['isFavorite'] = true,
      ],
      'tombstones': [
        {'id': '3', 'deletedAt': now.toUtc().toIso8601String()},
      ],
    });
    expect(section.countItems(data, version: 1), 2);
    expect(await section.countLocalItems(), 2);
  });

  test('replace makes the backup the history', () async {
    await repository.add(_entry('mine'));

    await section.restore(
      _throughJson({
        'entries': [_entry('a').toJson(), _entry('b', minute: 1).toJson()],
        'tombstones': [
          {'id': 'gone', 'deletedAt': now.toUtc().toIso8601String()},
        ],
      }),
      version: 1,
      mode: BackupRestoreMode.replace,
    );

    final data = await repository.backupData();
    expect(data.entries.map((e) => e.id), ['b', 'a']);
    expect(data.tombstones.single.id, 'gone');
  });

  test('merge keeps both sides and applies tombstones', () async {
    await repository.add(_entry('mine'));
    await repository.add(_entry('deleted there', minute: 1));

    await section.restore(
      _throughJson({
        'entries': [_entry('theirs', minute: 2).toJson()],
        'tombstones': [
          {'id': 'deleted there', 'deletedAt': now.toUtc().toIso8601String()},
        ],
      }),
      version: 1,
      mode: BackupRestoreMode.merge,
    );

    expect((await repository.backupData()).entries.map((e) => e.id), [
      'theirs',
      'mine',
    ]);
  });

  group('retention', () {
    final fresh = HistoryEntry(
      id: 'fresh',
      text: 'text',
      translation: 'translation',
      source: const Language(code: 'en', name: 'English'),
      target: const Language(code: 'fr', name: 'French'),
      engineId: 'mozhi:google',
      engineName: 'Engine',
      createdAt: now.subtract(const Duration(hours: 1)),
    );
    final backup = _throughJson({
      'entries': [_entry('old').toJson(), fresh.toJson()],
    });
    var asked = 0;

    setUp(() => asked = 0);

    HistoryBackupSection withRetention(Future<Duration?> Function() maxAge) =>
        HistoryBackupSection(
          repository,
          maxAge: () {
            asked++;
            return maxAge();
          },
        );

    test("merge leaves out what this device's retention deletes", () async {
      await withRetention(() async => const Duration(days: 1))
          .restore(backup, version: 1, mode: BackupRestoreMode.merge);

      expect((await repository.backupData()).entries.map((e) => e.id), [
        'fresh',
      ]);
      expect(asked, 1);
    });

    test('merge keeps everything without a retention, or when it cannot '
        'be read', () async {
      await withRetention(() async => null)
          .restore(backup, version: 1, mode: BackupRestoreMode.merge);
      expect((await repository.backupData()).entries, hasLength(2));

      // Another device (clearing would leave tombstones).
      repository = HistoryRepository(
        store: MemoryStore(),
        keyStore: MemoryStore(),
        clock: () => now,
      );
      await withRetention(() async => throw StateError('io'))
          .restore(backup, version: 1, mode: BackupRestoreMode.merge);
      expect((await repository.backupData()).entries, hasLength(2));
    });

    test('replace does not ask (the next load applies it)', () async {
      await withRetention(() async => const Duration(days: 1))
          .restore(backup, version: 1, mode: BackupRestoreMode.replace);

      expect((await repository.backupData()).entries, hasLength(2));
      expect(asked, 0);
    });
  });

  test('skips invalid entries and tombstones', () async {
    await section.restore(
      _throughJson({
        'entries': [
          _entry('ok').toJson(),
          {'id': 'broken'},
          7,
        ],
        'tombstones': [
          {'id': 'x'},
          'y',
        ],
      }),
      version: 1,
      mode: BackupRestoreMode.replace,
    );

    final data = await repository.backupData();
    expect(data.entries.map((e) => e.id), ['ok']);
    expect(data.tombstones, isEmpty);
  });

  test('reads data without tombstones', () {
    expect(
      section.countItems({
        'entries': [_entry('1').toJson()],
      }, version: 1),
      1,
    );
  });

  test('refuses newer versions and invalid data', () async {
    await expectLater(
      section.restore(
        {'entries': <Object?>[]},
        version: 2,
        mode: BackupRestoreMode.merge,
      ),
      throwsFormatException,
    );
    await expectLater(
      section.restore([1], version: 1, mode: BackupRestoreMode.merge),
      throwsFormatException,
    );
    expect(section.countItems(null, version: 1), isNull);
  });

  group('syncData', () {
    final today = DateTime.utc(2026, 10, 20);
    var clock = DateTime.utc(2026, 10, 20, 9);
    Duration? keeps;

    setUp(() {
      clock = DateTime.utc(2026, 10, 20, 9);
      keeps = const Duration(days: 7);
    });

    HistoryBackupSection build() => HistoryBackupSection(
      repository,
      maxAge: () async => keeps,
      clock: () => clock,
    );

    Map<String, Object?> entry(
      String id,
      Duration age, {
      bool favorite = false,
    }) => HistoryEntry(
      id: id,
      text: 'text $id',
      translation: 'translation $id',
      source: const Language(code: 'en', name: 'English'),
      target: const Language(code: 'fr', name: 'French'),
      engineId: 'mozhi:google',
      engineName: 'Engine',
      createdAt: clock.subtract(age),
      isFavorite: favorite,
    ).toJson();

    Map<String, Object?> record(int? seconds, DateTime seenAt) => {
      'maxAgeSeconds': seconds,
      'seenAt': seenAt.toIso8601String(),
    };

    Future<Map<String, Object?>> syncData(
      Map<String, Object?> local, {
      Object? remote,
      int? remoteVersion = 1,
    }) async => Map.from(
      _throughJson(
            await build().syncData(
              local,
              remote: remote,
              remoteVersion: remote == null ? null : remoteVersion,
            ),
          )!
          as Map,
    );

    List<Object?> ids(Map<String, Object?> data) => [
      for (final json in data['entries']! as List) (json! as Map)['id'],
    ];

    test("adds this device's retention to the file, renewed weekly", () async {
      final first = await syncData({'entries': <Object?>[]});
      expect(first['retention'], [record(604800, today)]);

      // Renewed only once it is a week old.
      clock = clock.add(const Duration(days: 3));
      final soon = await syncData({'entries': <Object?>[]}, remote: first);
      expect(soon['retention'], [record(604800, today)]);
      clock = clock.add(const Duration(days: 4));
      final later = await syncData({'entries': <Object?>[]}, remote: first);
      expect(later['retention'], [record(604800, DateTime.utc(2026, 10, 27))]);
    });

    test("keeps the file's entries this device's retention dropped while "
        'another device keeps them', () async {
      final local = {
        'entries': [entry('fresh', const Duration(hours: 1))],
        'tombstones': [
          {'id': 'deleted', 'deletedAt': clock.toIso8601String()},
        ],
      };
      final remote = {
        'entries': [
          entry('fresh', const Duration(hours: 1)),
          entry('recent', const Duration(days: 2)),
          entry('mid', const Duration(days: 10)),
          entry('deleted', const Duration(days: 12)),
          entry('starred', const Duration(days: 13), favorite: true),
          entry('old', const Duration(days: 40)),
          {'id': 'broken'},
        ],
        'retention': [record(2592000, today)],
      };

      final data = await syncData(local, remote: remote);
      // Within the 30 days the other device keeps, not deleted, not a
      // favorite (those are never dropped by the retention), and dropped
      // here by age (recent was dropped for another reason).
      expect(ids(data), ['fresh', 'mid']);
      expect(data['tombstones'], local['tombstones']);
      expect(data['retention'], [
        record(604800, today),
        record(2592000, today),
      ]);

      // A device that keeps history for ever: everything it doesn't
      // hold, in order of creation.
      remote['retention'] = [record(null, today)];
      final forever = await syncData(local, remote: remote);
      expect(ids(forever), ['fresh', 'mid', 'old']);
      expect(forever['retention'], [
        record(604800, today),
        record(null, today),
      ]);
    });

    test('keeps nothing for others when this device keeps everything, or '
        'without records (earlier versions)', () async {
      final remote = {
        'entries': [entry('old', const Duration(days: 40))],
      };
      expect(
        ids(await syncData({'entries': <Object?>[]}, remote: remote)),
        isEmpty,
      );
      keeps = null;
      remote['retention'] = [record(null, today)];
      final data = await syncData({'entries': <Object?>[]}, remote: remote);
      expect(ids(data), isEmpty);
      expect(data['retention'], [record(null, today)]);
    });

    test('a record not renewed for 30 days no longer counts; invalid ones '
        'are dropped', () async {
      final remote = {
        'entries': [entry('old', const Duration(days: 20))],
        'retention': [
          record(null, clock.subtract(const Duration(days: 31))),
          record(-1, today),
          {'maxAgeSeconds': 'week', 'seenAt': today.toIso8601String()},
          {'seenAt': today.toIso8601String()},
          {'maxAgeSeconds': 60, 'seenAt': 'yesterday'},
          'nonsense',
          record(2592000, clock.subtract(const Duration(days: 29))),
          record(2592000, clock.subtract(const Duration(days: 40))),
        ],
      };
      final data = await syncData({'entries': <Object?>[]}, remote: remote);
      expect(ids(data), ['old']);
      expect(data['retention'], [
        record(604800, today),
        record(2592000, clock.subtract(const Duration(days: 29))),
      ]);
    });

    test(
      "puts the kept entries among this device's by creation time",
      () async {
        final local = {
          'entries': [
            entry('a', const Duration(days: 1)),
            entry('starred', const Duration(days: 20), favorite: true),
          ],
        };
        final remote = {
          'entries': [
            entry('b', const Duration(days: 8)),
            entry('c', const Duration(days: 30)),
          ],
          'retention': [record(null, today)],
        };
        expect(ids(await syncData(local, remote: remote)), [
          'a',
          'b',
          'starred',
          'c',
        ]);
      },
    );

    test('a newer version of the file keeps its records out; odd data '
        'passes through', () async {
      final remote = {
        'entries': [entry('old', const Duration(days: 40))],
        'retention': [record(null, today)],
      };
      final data = await syncData(
        {'entries': <Object?>[]},
        remote: remote,
        remoteVersion: 2,
      );
      expect(ids(data), isEmpty);
      expect(data['retention'], [record(604800, today)]);
      expect(
        await build().syncData(null, remote: remote, remoteVersion: 1),
        isNull,
      );
      expect(
        ids(await syncData({'entries': <Object?>[]}, remote: 'odd')),
        isEmpty,
      );
    });

    test('a retention that cannot be read counts as for ever', () async {
      final section = HistoryBackupSection(
        repository,
        maxAge: () async => throw StateError('io'),
        clock: () => clock,
      );
      final data = Map<String, Object?>.from(
        _throughJson(
              await section.syncData(
                {'entries': <Object?>[]},
                remote: null,
                remoteVersion: null,
              ),
            )!
            as Map,
      );
      expect(data['retention'], [record(null, today)]);
    });
  });
}
