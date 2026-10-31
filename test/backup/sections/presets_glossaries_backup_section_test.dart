import 'dart:convert';

import 'package:flutter_test/flutter_test.dart';
import 'package:mozhi/backup/data/backup_registry.dart';
import 'package:mozhi/backup/sections/glossaries_backup_section.dart';
import 'package:mozhi/backup/sections/presets_backup_section.dart';
import 'package:mozhi/core/key_value_store.dart';
import 'package:mozhi/presets/data/glossary_repository.dart';
import 'package:mozhi/presets/data/merge_copies.dart';
import 'package:mozhi/presets/data/presets_repository.dart';
import 'package:mozhi/presets/models/glossary.dart';
import 'package:mozhi/presets/models/preset.dart';
import 'package:translation_repository/translation_repository.dart';

Object? _throughJson(Object? data) => jsonDecode(jsonEncode(data));

/// The time of the sections' repositories.
final _now = DateTime.utc(2026, 10, 20, 12);

void main() {
  late MemoryStore store;

  setUp(() => store = MemoryStore());

  group(PresetsBackupSection, () {
    late PresetsRepository repository;
    late PresetsBackupSection section;
    const formal = Preset(
      id: 'p1',
      name: 'Formal',
      options: TranslationOptions(formality: Formality.more),
    );
    const casual = Preset(
      id: 'p2',
      name: 'Casual',
      options: TranslationOptions(formality: Formality.less),
    );
    const theirFormal = Preset(id: 'p1', name: 'Their formal');

    setUp(() async {
      repository = PresetsRepository(store: store, clock: () => _now);
      section = PresetsBackupSection(repository);
      await repository.save(
        const PresetCollection(presets: [formal], defaultId: 'p1'),
      );
    });

    test('has its id and version', () {
      expect(section.id, 'presets');
      expect(section.version, 2);
    });

    test('exports the stored presets', () async {
      final data = await section.export(includeSecrets: false);

      expect(
        PresetCollection.tryParse(_throughJson(data)),
        const PresetCollection(presets: [formal], defaultId: 'p1'),
      );
      expect(section.countItems(_throughJson(data), version: 1), 1);
      expect(await section.countLocalItems(), 1);
    });

    test('replace makes the backup the presets', () async {
      await section.restore(
        _throughJson(
          const PresetCollection(presets: [casual, theirFormal]).toJson(),
        ),
        version: 1,
        mode: BackupRestoreMode.replace,
      );

      expect(
        await repository.load(),
        const PresetCollection(presets: [casual, theirFormal]),
      );
    });

    test("merge keeps this device's presets and default and adds the "
        'others', () async {
      await section.restore(
        _throughJson(
          const PresetCollection(
            presets: [theirFormal, casual],
            defaultId: 'p2',
          ).toJson(),
        ),
        version: 1,
        mode: BackupRestoreMode.merge,
      );

      expect(
        await repository.load(),
        const PresetCollection(presets: [formal, casual], defaultId: 'p1'),
      );
    });

    test("merge takes the backup's default when there is none here (and "
        'neither copy says when it changed)', () async {
      await repository.replaceAll(const PresetCollection(presets: [formal]));

      await section.restore(
        _throughJson(
          const PresetCollection(presets: [casual], defaultId: 'p2').toJson(),
        ),
        version: 1,
        mode: BackupRestoreMode.merge,
      );

      expect((await repository.load()).defaultId, 'p2');
    });

    test('refuses newer versions and invalid data', () async {
      await expectLater(
        section.restore(
          const PresetCollection().toJson(),
          version: 3,
          mode: BackupRestoreMode.replace,
        ),
        throwsFormatException,
      );
      await expectLater(
        section.restore('x', version: 1, mode: BackupRestoreMode.replace),
        throwsFormatException,
      );
      expect(section.countItems('x', version: 1), isNull);
      expect(section.countItems(const <Object?>[], version: 3), isNull);
    });

    group('version 2', () {
      final now = DateTime.utc(2026, 10, 20, 9);
      final later = now.add(const Duration(hours: 1));

      PresetsRepository device(MemoryStore store, DateTime Function() clock) =>
          PresetsRepository(store: store, clock: clock);

      test('exports change times and tombstones', () async {
        final repository = device(store, () => now);
        await repository.replaceAll(
          PresetCollection(
            presets: [formal.copyWith(updatedAt: now)],
            defaultId: 'p1',
            orderUpdatedAt: now,
            defaultUpdatedAt: now,
          ),
          tombstones: [Tombstone(id: 'p2', deletedAt: now)],
        );

        final data = _throughJson(
          await PresetsBackupSection(repository).export(includeSecrets: false),
        );

        expect(data, {
          'version': 1,
          'defaultId': 'p1',
          'orderUpdatedAt': '2026-10-20T09:00:00.000Z',
          'defaultUpdatedAt': '2026-10-20T09:00:00.000Z',
          'presets': [formal.copyWith(updatedAt: now).toJson()],
          'tombstones': [
            {'id': 'p2', 'deletedAt': '2026-10-20T09:00:00.000Z'},
          ],
        });
        expect(section.countItems(data, version: 2), 1);
      });

      test('replace takes the tombstones too', () async {
        await section.restore(
          _throughJson({
            ...const PresetCollection(presets: [casual]).toJson(),
            'tombstones': [
              {'id': 'p1', 'deletedAt': '2026-10-20T09:00:00.000Z'},
            ],
          }),
          version: 2,
          mode: BackupRestoreMode.replace,
        );

        final data = await repository.backupData();
        expect(data.collection, const PresetCollection(presets: [casual]));
        expect(data.tombstones, [Tombstone(id: 'p1', deletedAt: now)]);
      });

      test('edits and deletions reach the other device', () async {
        var clock = now;
        final phone = device(MemoryStore(), () => clock);
        final tablet = device(MemoryStore(), () => clock);
        final phoneSection = PresetsBackupSection(phone);
        final tabletSection = PresetsBackupSection(tablet);
        Future<void> sync(
          PresetsBackupSection from,
          PresetsBackupSection to,
        ) async {
          final data = _throughJson(await from.export(includeSecrets: false));
          await to.restore(data, version: 2, mode: BackupRestoreMode.merge);
        }

        // A tablet without the examples (deleted before presets had
        // tombstones).
        await tablet.replaceAll(const PresetCollection());
        await phone.save(const PresetCollection(presets: [formal, casual]));
        await sync(phoneSection, tabletSection);
        expect((await tablet.load()).presets, const [formal, casual]);

        // The phone renames one and deletes the other.
        clock = later;
        await phone.save(
          PresetCollection(
            presets: [formal.copyWith(name: 'Renamed', updatedAt: later)],
          ),
          deleted: ['p2'],
        );
        await sync(phoneSection, tabletSection);

        expect((await tablet.load()).presets.map((p) => p.name), ['Renamed']);

        // And back: nothing comes back to the phone.
        await sync(tabletSection, phoneSection);
        expect((await phone.load()).presets.map((p) => p.name), ['Renamed']);
      });

      test('restores version 1 data', () async {
        await section.restore(
          _throughJson(const PresetCollection(presets: [casual]).toJson()),
          version: 1,
          mode: BackupRestoreMode.merge,
        );

        expect((await repository.load()).presets, const [formal, casual]);
        expect(section.countItems([casual.toJson()], version: 1), 1);
      });
    });
  });

  group(GlossariesBackupSection, () {
    late GlossaryRepository repository;
    late GlossariesBackupSection section;
    const mine = Glossary(
      id: 'g1',
      name: 'Work',
      terms: [GlossaryTerm(source: 'deck', target: 'Foliensatz')],
    );
    const theirs = Glossary(id: 'g1', name: 'Their work');
    const other = Glossary(
      id: 'g2',
      name: 'Travel',
      terms: [GlossaryTerm(source: 'bus', target: 'Bus')],
    );

    setUp(() async {
      repository = GlossaryRepository(store: store, clock: () => _now);
      section = GlossariesBackupSection(repository);
      await repository.save([mine]);
    });

    test('has its id and version', () {
      expect(section.id, 'glossaries');
      expect(section.version, 2);
    });

    test('exports the stored glossaries', () async {
      final data = _throughJson(await section.export(includeSecrets: false));

      expect(GlossaryRepository.parseGlossaries(data), [mine]);
      expect(section.countItems(data, version: 1), 1);
      expect(await section.countLocalItems(), 1);
    });

    test('replace makes the backup the glossaries', () async {
      await section.restore(
        _throughJson(GlossaryRepository.encode([other])),
        version: 1,
        mode: BackupRestoreMode.replace,
      );

      expect(await repository.load(), [other]);
    });

    test(
      "merge keeps this device's newer glossaries and adds the others",
      () async {
        final changed = mine.copyWith(updatedAt: _now);
        await repository.save([changed]);
        await section.restore(
          _throughJson(GlossaryRepository.encode([theirs, other])),
          version: 1,
          mode: BackupRestoreMode.merge,
        );

        expect(await repository.load(), [changed, other]);
      },
    );

    test('merge decides between two copies without change times the same '
        'way on every device', () async {
      await section.restore(
        _throughJson(GlossaryRepository.encode([theirs, other])),
        version: 1,
        mode: BackupRestoreMode.merge,
      );

      final winner =
          tieBreak(canonicalJson(mine.toJson()), canonicalJson(theirs.toJson()))
          ? theirs
          : mine;
      expect(await repository.load(), [winner, other]);
    });

    test('refuses newer versions and invalid data', () async {
      await expectLater(
        section.restore(
          GlossaryRepository.encode(const []),
          version: 3,
          mode: BackupRestoreMode.merge,
        ),
        throwsFormatException,
      );
      await expectLater(
        section.restore(7, version: 1, mode: BackupRestoreMode.merge),
        throwsFormatException,
      );
      expect(section.countItems(7, version: 1), isNull);
    });

    group('version 2', () {
      final now = DateTime.utc(2026, 10, 20, 9);
      final later = now.add(const Duration(hours: 1));

      test('exports change times and tombstones', () async {
        final repository = GlossaryRepository(store: store, clock: () => now);
        await repository.replaceAll(
          [mine.copyWith(updatedAt: now)],
          orderUpdatedAt: now,
          tombstones: [Tombstone(id: 'g2', deletedAt: now)],
        );

        final data = _throughJson(
          await GlossariesBackupSection(repository)
              .export(includeSecrets: false),
        );

        expect(data, {
          'version': 1,
          'orderUpdatedAt': '2026-10-20T09:00:00.000Z',
          'glossaries': [mine.copyWith(updatedAt: now).toJson()],
          'tombstones': [
            {'id': 'g2', 'deletedAt': '2026-10-20T09:00:00.000Z'},
          ],
        });
        expect(section.countItems(data, version: 2), 1);
      });

      test('replace takes the order time and tombstones too', () async {
        await section.restore(
          _throughJson({
            ...GlossaryRepository.encode(const [other], orderUpdatedAt: now),
            'tombstones': [
              {'id': 'g1', 'deletedAt': '2026-10-20T09:00:00.000Z'},
            ],
          }),
          version: 2,
          mode: BackupRestoreMode.replace,
        );

        final data = await repository.backupData();
        expect(data.glossaries, const [other]);
        expect(data.orderUpdatedAt, now);
        expect(data.tombstones, [Tombstone(id: 'g1', deletedAt: now)]);
      });

      test('edits, deletions and the order reach the other device', () async {
        var clock = now;
        final phone = GlossaryRepository(
          store: MemoryStore(),
          clock: () => clock,
        );
        final tablet = GlossaryRepository(
          store: MemoryStore(),
          clock: () => clock,
        );
        final phoneSection = GlossariesBackupSection(phone);
        final tabletSection = GlossariesBackupSection(tablet);
        Future<void> sync(
          GlossariesBackupSection from,
          GlossariesBackupSection to,
        ) async {
          final data = _throughJson(await from.export(includeSecrets: false));
          await to.restore(data, version: 2, mode: BackupRestoreMode.merge);
        }

        const third = Glossary(id: 'g3', name: 'Third');
        await phone.save(const [mine, other, third]);
        await sync(phoneSection, tabletSection);

        clock = later;
        await phone.save(
          [third, mine.copyWith(enabled: false, updatedAt: later)],
          deleted: ['g2'],
        );
        await sync(phoneSection, tabletSection);

        final synced = await tablet.load();
        expect(synced.map((g) => (g.id, g.enabled)), [
          ('g3', true),
          ('g1', false),
        ]);
        await sync(tabletSection, phoneSection);
        expect(await phone.load(), synced);
      });

      test('restores version 1 data', () async {
        await section.restore(
          _throughJson(GlossaryRepository.encode(const [other])),
          version: 1,
          mode: BackupRestoreMode.merge,
        );

        expect(await repository.load(), [mine, other]);
      });
    });
  });
}
