import 'dart:typed_data';

import 'package:flutter_test/flutter_test.dart';
import 'package:mozhi/backup/data/backup_registry.dart';
import 'package:mozhi/backup/sections/history_backup_section.dart';
import 'package:mozhi/core/key_value_store.dart';
import 'package:mozhi/history/data/history_repository.dart';
import 'package:mozhi/history/models/history_entry.dart';
import 'package:mozhi/pairing/data/pairing_packs.dart';
import 'package:mozhi/pairing/models/pairing_item.dart';
import 'package:translation_repository/translation_repository.dart';

HistoryEntry _entry(String id, DateTime createdAt) => HistoryEntry(
  id: id,
  text: 'text $id',
  translation: 'translation $id',
  source: const Language(code: 'en', name: 'English'),
  target: const Language(code: 'fr', name: 'French'),
  engineId: 'mozhi:google',
  engineName: 'Engine',
  createdAt: createdAt,
);

/// A phone that cleared its history sends its data to another phone: the
/// receiving phone keeps its own history.
void main() {
  final now = DateTime.utc(2026, 10, 20, 9);

  Future<(HistoryRepository, BackupRegistry)> phone() async {
    final history = HistoryRepository(
      store: MemoryStore(),
      keyStore: MemoryStore(),
      clock: () => now,
    );
    final registry = BackupRegistry(appVersion: () async => '1')
      ..register(HistoryBackupSection(history));
    return (history, registry);
  }

  for (final mode in BackupRestoreMode.values) {
    test("the sender's Clear history never takes the receiver's entries "
        '(${mode.name})', () async {
      final (senderHistory, sender) = await phone();
      await senderHistory.add(
        _entry('sent', now.subtract(const Duration(hours: 1))),
      );
      await senderHistory.clear(keepFavorites: true);
      await senderHistory.add(_entry('after', now));
      final outgoing = await PairingBackupItem.outgoing(
        sender,
        sections: {HistoryBackupSection.sectionId},
        includeSecrets: false,
      );
      final bytes = await outgoing.readers.values.single().first;
      expect(
        String.fromCharCodes(bytes),
        contains('"cleared"'),
        reason: 'the record travels with the data',
      );

      final (receiverHistory, receiver) = await phone();
      await receiverHistory.add(
        _entry('mine', now.subtract(const Duration(days: 30))),
      );
      final outcome = await PairingBackupItem.restore(
        receiver,
        PairingItem(
          kind: PairingItemKind.data,
          key: PairingBackupItem.key,
          files: [
            PairingFile(name: PairingBackupItem.fileName, size: bytes.length),
          ],
          sections: const [HistoryBackupSection.sectionId],
        ),
        Uint8List.fromList(bytes),
        mode: mode,
      );

      expect(outcome, PairingItemOutcome.installed);
      final data = await receiverHistory.backupData();
      expect(data.entries.map((e) => e.id), [
        'after',
        if (mode == BackupRestoreMode.merge) 'mine',
      ]);
      expect(data.cleared, HistoryCleared.none);
    });
  }
}
