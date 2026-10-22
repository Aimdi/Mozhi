import 'package:mozhi/backup/data/backup_registry.dart';
import 'package:mozhi/presets/data/glossary_repository.dart';
import 'package:mozhi/presets/models/glossary.dart';

/// The saved glossaries ([Glossary]) with their deletion tombstones
/// ([Tombstone]), section `glossaries`.
///
/// Data (version 2): the glossaries' storage document
/// (`GlossaryRepository.encode`: glossaries with their `updatedAt`, and
/// when they were last reordered) plus `"tombstones":
/// [Tombstone.toJson()...]`. Version 1 (the storage document without
/// change times or tombstones) is still restored.
///
/// [BackupRestoreMode.replace] makes the backup the glossaries
/// ([GlossaryRepository.replaceAll]). [BackupRestoreMode.merge]
/// ([GlossaryRepository.mergeBackup]) keeps the newer copy of each
/// glossary, lets tombstones delete older copies, and takes the order from
/// the copy reordered last; glossaries without change times (version 1, or
/// not changed since) lose to every change and deletion, and on a tie this
/// device's copy stays.
class GlossariesBackupSection implements BackupSection, BackupItemCounter {
  const new(this._repository);

  /// The section's [id].
  static const sectionId = 'glossaries';

  final GlossaryRepository _repository;

  @override
  String get id => sectionId;

  @override
  int get version => 2;

  @override
  Future<Object?> export({required bool includeSecrets}) async {
    final (:glossaries, :orderUpdatedAt, :tombstones) = await _repository
        .backupData();
    return {
      ...GlossaryRepository.encode(glossaries, orderUpdatedAt: orderUpdatedAt),
      'tombstones': [for (final tombstone in tombstones) tombstone.toJson()],
    };
  }

  @override
  Future<void> restore(
    Object? data, {
    required int version,
    required BackupRestoreMode mode,
  }) async {
    final (:glossaries, :orderUpdatedAt, :tombstones) = _parse(data, version);
    switch (mode) {
      case BackupRestoreMode.replace:
        await _repository.replaceAll(
          glossaries,
          orderUpdatedAt: orderUpdatedAt,
          tombstones: tombstones,
        );
      case BackupRestoreMode.merge:
        await _repository.mergeBackup(
          glossaries,
          orderUpdatedAt: orderUpdatedAt,
          tombstones: tombstones,
        );
    }
  }

  @override
  int? countItems(Object? data, {required int version}) {
    try {
      return _parse(data, version).glossaries.length;
    } on FormatException {
      return null;
    }
  }

  @override
  Future<int> countLocalItems() async => (await _repository.load()).length;

  ({
    List<Glossary> glossaries,
    DateTime? orderUpdatedAt,
    List<Tombstone> tombstones,
  })
  _parse(Object? data, int version) {
    if (version > this.version) {
      throw FormatException('Glossaries data version $version is newer');
    }
    final glossaries =
        GlossaryRepository.parseGlossaries(data) ??
        (throw const FormatException('Invalid glossaries data'));
    return (
      glossaries: glossaries,
      orderUpdatedAt: GlossaryRepository.parseOrderUpdatedAt(data),
      tombstones: data is Map
          ? Tombstone.parseList(data['tombstones'])
          : const <Tombstone>[],
    );
  }
}
