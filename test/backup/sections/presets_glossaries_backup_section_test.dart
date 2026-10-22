import 'dart:convert';

import 'package:flutter_test/flutter_test.dart';
import 'package:mozhi/backup/data/backup_registry.dart';
import 'package:mozhi/backup/sections/glossaries_backup_section.dart';
import 'package:mozhi/backup/sections/presets_backup_section.dart';
import 'package:mozhi/core/key_value_store.dart';
import 'package:mozhi/presets/data/glossary_repository.dart';
import 'package:mozhi/presets/data/presets_repository.dart';
import 'package:mozhi/presets/models/glossary.dart';
import 'package:mozhi/presets/models/preset.dart';
import 'package:translation_repository/translation_repository.dart';

Object? _throughJson(Object? data) => jsonDecode(jsonEncode(data));

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
      repository = PresetsRepository(store: store);
      section = PresetsBackupSection(repository);
      await repository.save(
        const PresetCollection(presets: [formal], defaultId: 'p1'),
      );
    });

    test('has its id and version', () {
      expect(section.id, 'presets');
      expect(section.version, 1);
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

    test("merge takes the backup's default when there is none here", () async {
      await repository.save(const PresetCollection(presets: [formal]));

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
          version: 2,
          mode: BackupRestoreMode.replace,
        ),
        throwsFormatException,
      );
      await expectLater(
        section.restore('x', version: 1, mode: BackupRestoreMode.replace),
        throwsFormatException,
      );
      expect(section.countItems('x', version: 1), isNull);
      expect(section.countItems(const <Object?>[], version: 2), isNull);
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
      repository = GlossaryRepository(store: store);
      section = GlossariesBackupSection(repository);
      await repository.save([mine]);
    });

    test('has its id and version', () {
      expect(section.id, 'glossaries');
      expect(section.version, 1);
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

    test("merge keeps this device's glossaries and adds the others", () async {
      await section.restore(
        _throughJson(GlossaryRepository.encode([theirs, other])),
        version: 1,
        mode: BackupRestoreMode.merge,
      );

      expect(await repository.load(), [mine, other]);
    });

    test('refuses newer versions and invalid data', () async {
      await expectLater(
        section.restore(
          GlossaryRepository.encode(const []),
          version: 2,
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
  });
}
