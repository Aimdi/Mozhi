/// How [BackupSection.restore] applies a backup.
enum BackupRestoreMode {
  /// The backup becomes the data (what isn't in it is removed).
  replace,

  /// Per entry, the newer copy wins (updatedAt, else createdAt); deletions
  /// recorded as tombstones in either copy win over older entries; entries
  /// only on one side are kept. Used by sync and "Restore and keep mine".
  merge,
}

/// One kind of data that backups, sync and pairing carry. Implementations
/// live with their feature (history, presets, phrasebook, practice...).
abstract interface class BackupSection {
  /// Stable id: 'settings', 'history', 'presets', 'glossaries',
  /// 'phrasebook', 'practice', ...
  String get id;

  /// Version of the data [export] writes; [restore] must accept every
  /// version up to it (and refuse newer ones with a FormatException).
  int get version;

  /// The section's data, JSON-encodable (maps, lists, strings, numbers,
  /// bools, null). [includeSecrets]: API keys and passwords (only the
  /// settings section has any); false unless the user opted in.
  Future<Object?> export({required bool includeSecrets});

  /// Applies [data] written by [export] at [version].
  Future<void> restore(
    Object? data, {
    required int version,
    required BackupRestoreMode mode,
  });
}

/// Optional for a [BackupSection]: how many items (entries, presets,
/// phrases...) its data holds, for the summary of a backup before it is
/// restored and for the result of a restore ("History: 135 entries, was
/// 120"). Sections without countable items need not implement it.
abstract interface class BackupItemCounter {
  /// How many items [data] (written by [BackupSection.export] at
  /// [version]) holds; null when that can't be told (e.g. a newer
  /// version).
  int? countItems(Object? data, {required int version});

  /// How many items this device holds now.
  Future<int> countLocalItems();
}
