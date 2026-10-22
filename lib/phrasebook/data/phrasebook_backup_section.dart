import 'package:mozhi/backup/models/backup_section.dart';
import 'package:mozhi/phrasebook/data/phrasebook_repository.dart';

/// The phrasebook in backups, sync and pairing (section id [sectionId]):
/// the user's collections, their phrases, the notes on favourites and the
/// deletion tombstones ([PhrasebookRepository.exportBackup]). Not the
/// favourites themselves (they are the history's section) nor the starter
/// phrasebooks (they can be downloaded again).
///
/// [BackupRestoreMode.replace] makes the backup the phrasebook;
/// [BackupRestoreMode.merge] keeps the newer copy of each phrase,
/// collection and note, lets tombstones win over older copies and keeps
/// what only one side has ([PhrasebookRepository.restoreBackup]).
class PhrasebookBackupSection implements BackupSection, BackupItemCounter {
  const new(this._repository);

  /// The section's id.
  static const sectionId = 'phrasebook';

  final PhrasebookRepository _repository;

  @override
  String get id => sectionId;

  @override
  int get version => PhrasebookRepository.backupVersion;

  @override
  Future<Object?> export({required bool includeSecrets}) =>
      _repository.exportBackup();

  @override
  Future<void> restore(
    Object? data, {
    required int version,
    required BackupRestoreMode mode,
  }) => _repository.restoreBackup(
    data,
    version: version,
    merge: mode == BackupRestoreMode.merge,
  );

  /// The phrases of [data] (stored phrases; favourites are counted by the
  /// history).
  @override
  int? countItems(Object? data, {required int version}) {
    if (version < 1 || version > this.version) return null;
    if (data case {'phrases': final List<Object?> phrases}) {
      return phrases.length;
    }
    return null;
  }

  @override
  Future<int> countLocalItems() async {
    final phrases = await _repository.phrases();
    return phrases.where((phrase) => phrase.isStored).length;
  }
}
