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
}
