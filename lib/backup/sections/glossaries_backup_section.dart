import 'package:mozhi/backup/data/backup_registry.dart';
import 'package:mozhi/presets/data/glossary_repository.dart';
import 'package:mozhi/presets/models/glossary.dart';

/// The saved glossaries ([Glossary]), section `glossaries`.
///
/// Data (version 1): the glossaries' storage document
/// (`GlossaryRepository.encode`). [BackupRestoreMode.replace] makes it the
/// glossaries. [BackupRestoreMode.merge] keeps this device's glossaries
/// and adds the backup's glossaries with other ids after them (glossaries
/// carry no timestamps, so this device's copy of a glossary wins).
class GlossariesBackupSection implements BackupSection, BackupItemCounter {
  const new(this._repository);

  /// The section's [id].
  static const sectionId = 'glossaries';

  final GlossaryRepository _repository;

  @override
  String get id => sectionId;

  @override
  int get version => 1;

  @override
  Future<Object?> export({required bool includeSecrets}) async =>
      GlossaryRepository.encode(await _repository.load());

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
        final ids = {for (final glossary in local) glossary.id};
        await _repository.save([
          ...local,
          for (final glossary in backup)
            if (!ids.contains(glossary.id)) glossary,
        ]);
    }
  }

  @override
  int? countItems(Object? data, {required int version}) {
    try {
      return _parse(data, version).length;
    } on FormatException {
      return null;
    }
  }

  @override
  Future<int> countLocalItems() async => (await _repository.load()).length;

  List<Glossary> _parse(Object? data, int version) {
    if (version > this.version) {
      throw FormatException('Glossaries data version $version is newer');
    }
    return GlossaryRepository.parseGlossaries(data) ??
        (throw const FormatException('Invalid glossaries data'));
  }
}
