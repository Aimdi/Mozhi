/// What a sync run tells the sections that merge the sync file in their own
/// way ([SyncMergeSection]).
class SyncMergeContext {
  const new({this.joinedAt});

  /// When this device started syncing with the folder (`SyncConfig.joinedAt`;
  /// null: unknown, as for a device set up before join times were
  /// recorded, which counts as syncing all along).
  final DateTime? joinedAt;
}

/// Optional for a `BackupSection` that sync carries and whose merge of the
/// sync file differs from that of a backup or a phone-to-phone transfer
/// (the history applies the folder's Clear history only in sync, see
/// `HistoryBackupSection`). Sync calls these instead of
/// `BackupSyncSection.syncData` and passes the merge data through
/// `BackupRegistry.restore`.
abstract interface class SyncMergeSection {
  /// The file's [data] of the section as `BackupSection.restore` takes it
  /// in a sync merge (an object only this section reads, never JSON).
  Object? forSyncMerge(Object? data, SyncMergeContext context);

  /// `BackupSyncSection.syncData` in [context].
  Future<Object?> syncDataIn(
    SyncMergeContext context,
    Object? local, {
    required Object? remote,
    required int? remoteVersion,
  });
}
