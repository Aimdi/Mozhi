import 'package:mozhi/backup/data/backup_registry.dart';
import 'package:mozhi/presets/data/presets_repository.dart';
import 'package:mozhi/presets/models/preset.dart';

/// The translation presets ([PresetCollection]) with their deletion
/// tombstones ([Tombstone]), section `presets`.
///
/// Data (version 2): the presets' storage document
/// (`PresetCollection.toJson`: presets with their `updatedAt`, the default,
/// and when the order and the default last changed) plus `"tombstones":
/// [Tombstone.toJson()...]`. Version 1 (the storage document without
/// change times or tombstones) is still restored.
///
/// [BackupRestoreMode.replace] makes the backup the presets
/// ([PresetsRepository.replaceAll]). [BackupRestoreMode.merge]
/// ([PresetsRepository.mergeBackup]) keeps the newer copy of each preset,
/// lets tombstones delete older copies, and takes the order and the
/// default from the copy where they changed last; presets without change
/// times (version 1, or not changed since) lose to every change and
/// deletion, and on a tie this device's copy stays.
class PresetsBackupSection implements BackupSection, BackupItemCounter {
  const new(this._repository);

  /// The section's [id].
  static const sectionId = 'presets';

  final PresetsRepository _repository;

  @override
  String get id => sectionId;

  @override
  int get version => 2;

  @override
  Future<Object?> export({required bool includeSecrets}) async {
    final (:collection, :tombstones) = await _repository.backupData();
    return {
      ...collection.toJson(),
      'tombstones': [for (final tombstone in tombstones) tombstone.toJson()],
    };
  }

  @override
  Future<void> restore(
    Object? data, {
    required int version,
    required BackupRestoreMode mode,
  }) async {
    final (:collection, :tombstones) = _parse(data, version);
    switch (mode) {
      case BackupRestoreMode.replace:
        await _repository.replaceAll(collection, tombstones: tombstones);
      case BackupRestoreMode.merge:
        await _repository.mergeBackup(collection, tombstones: tombstones);
    }
  }

  @override
  int? countItems(Object? data, {required int version}) {
    try {
      return _parse(data, version).collection.presets.length;
    } on FormatException {
      return null;
    }
  }

  @override
  Future<int> countLocalItems() async =>
      (await _repository.load()).presets.length;

  ({PresetCollection collection, List<Tombstone> tombstones}) _parse(
    Object? data,
    int version,
  ) {
    if (version > this.version) {
      throw FormatException('Presets data version $version is newer');
    }
    final collection =
        PresetCollection.tryParse(data) ??
        (throw const FormatException('Invalid presets data'));
    return (
      collection: collection,
      tombstones: data is Map
          ? Tombstone.parseList(data['tombstones'])
          : const <Tombstone>[],
    );
  }
}
