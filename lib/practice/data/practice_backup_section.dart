import 'package:mozhi/backup/models/backup_section.dart';
import 'package:mozhi/practice/data/practice_repository.dart';

/// The `practice` section of backups, sync and pairing: the progress of
/// every card reviewed so far, the deletion tombstones and the practice
/// settings ([PracticeRepository.exportBackup]). The phrases themselves
/// are the phrasebook's section.
class PracticeBackupSection implements BackupSection, BackupItemCounter {
  const new(this.repository);

  /// The section's id.
  static const sectionId = 'practice';

  final PracticeRepository repository;

  @override
  String get id => sectionId;

  @override
  int get version => PracticeRepository.backupVersion;

  @override
  Future<Object?> export({required bool includeSecrets}) =>
      repository.exportBackup();

  @override
  Future<void> restore(
    Object? data, {
    required int version,
    required BackupRestoreMode mode,
  }) => repository.restoreBackup(
    data,
    version: version,
    merge: mode == BackupRestoreMode.merge,
  );

  /// The cards reviewed at least once.
  @override
  int? countItems(Object? data, {required int version}) =>
      PracticeRepository.countBackupCards(data, version: version);

  @override
  Future<int> countLocalItems() => repository.reviewedCount();
}
