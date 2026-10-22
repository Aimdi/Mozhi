import 'package:mozhi/backup/data/backup_registry.dart';
import 'package:mozhi/presets/data/presets_repository.dart';
import 'package:mozhi/presets/models/preset.dart';

/// The translation presets ([PresetCollection]), section `presets`.
///
/// Data (version 1): the presets' storage document
/// (`PresetCollection.toJson`). [BackupRestoreMode.replace] makes it the
/// presets. [BackupRestoreMode.merge] keeps this device's presets (and its
/// default) and adds the backup's presets with other ids after them:
/// presets carry no timestamps, so this device's copy of a preset wins,
/// and one deleted here comes back when the backup still has it.
class PresetsBackupSection implements BackupSection, BackupItemCounter {
  const new(this._repository);

  /// The section's [id].
  static const sectionId = 'presets';

  final PresetsRepository _repository;

  @override
  String get id => sectionId;

  @override
  int get version => 1;

  @override
  Future<Object?> export({required bool includeSecrets}) async =>
      (await _repository.load()).toJson();

  @override
  Future<void> restore(
    Object? data, {
    required int version,
    required BackupRestoreMode mode,
  }) async {
    final backup = _parse(data, version);
    switch (mode) {
      case BackupRestoreMode.replace:
        await _repository.save(backup);
      case BackupRestoreMode.merge:
        final local = await _repository.load();
        final ids = {for (final preset in local.presets) preset.id};
        await _repository.save(
          PresetCollection(
            presets: List.unmodifiable([
              ...local.presets,
              for (final preset in backup.presets)
                if (!ids.contains(preset.id)) preset,
            ]),
            defaultId: local.defaultId ?? backup.defaultId,
          ),
        );
    }
  }

  @override
  int? countItems(Object? data, {required int version}) {
    try {
      return _parse(data, version).presets.length;
    } on FormatException {
      return null;
    }
  }

  @override
  Future<int> countLocalItems() async =>
      (await _repository.load()).presets.length;

  PresetCollection _parse(Object? data, int version) {
    if (version > this.version) {
      throw FormatException('Presets data version $version is newer');
    }
    return PresetCollection.tryParse(data) ??
        (throw const FormatException('Invalid presets data'));
  }
}
