import 'dart:convert';

import 'package:flutter_test/flutter_test.dart';
import 'package:mozhi/backup/models/backup_section.dart';
import 'package:mozhi/core/key_value_store.dart';
import 'package:mozhi/phrasebook/data/phrasebook_backup_section.dart';
import 'package:mozhi/phrasebook/data/phrasebook_repository.dart';

import '../helpers.dart';

const _hello = PhraseDraft(
  text: 'Hello',
  translation: 'Olá',
  sourceCode: 'en',
  targetCode: 'pt',
);

void main() {
  PhrasebookRepository repo() => PhrasebookRepository(
    store: MemoryStore(),
    keyStore: MemoryStore(),
    favorites: FakeFavorites([favoriteEntry('1')]),
  );

  test('exports, counts and restores the phrasebook', () async {
    final source = repo();
    final lisbon = await source.createCollection('Lisbon');
    await source.addPhrase(_hello, lisbon.id);
    final section = PhrasebookBackupSection(source);
    expect(section.id, 'phrasebook');
    expect(section.version, 1);
    final data = jsonDecode(
      jsonEncode(await section.export(includeSecrets: true)),
    );
    expect(section.countItems(data, version: 1), 1);
    expect(section.countItems(data, version: 2), isNull);
    expect(section.countItems('x', version: 1), isNull);
    // The favourite is the history's.
    expect(await section.countLocalItems(), 1);

    final target = repo();
    final other = PhrasebookBackupSection(target);
    await other.restore(data, version: 1, mode: BackupRestoreMode.merge);
    expect(await other.countLocalItems(), 1);
    await target.createCollection('Porto');
    await other.restore(data, version: 1, mode: BackupRestoreMode.replace);
    expect((await target.collections()).map((c) => c.name), ['', 'Lisbon']);
    await expectLater(
      other.restore(data, version: 2, mode: BackupRestoreMode.replace),
      throwsFormatException,
    );
  });
}
