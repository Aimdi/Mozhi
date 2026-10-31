import 'dart:convert';
import 'dart:typed_data';

import 'package:cryptography/dart.dart';
import 'package:mozhi/backup/data/backup_codec.dart';
import 'package:mozhi/backup/data/backup_registry.dart';
import 'package:mozhi/sync/data/webdav_client.dart';
import 'package:mozhi/sync/models/sync_config.dart';
import 'package:mozhi/sync/models/sync_status.dart';

/// What one [SyncEngine.run] did: its [result] and the [cursor] to start
/// the next run from. [skipped] when nothing synced had changed on this
/// device and the run was only for local changes (no request was made).
class SyncRun {
  const new({required this.result, required this.cursor, this.report})
    : skipped = false;

  /// A run that found nothing to do without asking the server.
  const new skipped(this.cursor)
    : result = SyncResult.unchanged,
      report = null,
      skipped = true;

  final SyncResult result;
  final SyncCursor? cursor;

  /// What merging the server's data changed here, when it was merged.
  final BackupRestoreReport? report;

  /// Whether the run made no request: nothing synced had changed here.
  final bool skipped;
}

/// The sync protocol: one encrypted snapshot ([SyncConfig.fileName], a
/// `.mozhibackup` file written with [BackupCodec.encryptWithKey]) per sync
/// folder, which every device merges into its own data and writes back.
///
/// A [run]:
/// 1. exports this device's synced sections and fingerprints them
///    (SHA-256 of their canonical JSON);
/// 2. reads the file (`GET`; with `If-None-Match` when nothing changed
///    here since the last run, so an unchanged file costs a `304`);
/// 3. decrypts it with the device's key: a file written with another key
///    is [SyncFailure.passphraseChanged], one that doesn't open
///    [SyncFailure.damaged], and one with sections from a newer app
///    version [SyncFailure.newerVersion]; in each case nothing here or on
///    the server changes;
/// 4. merges it into this device's data
///    (`BackupRegistry.restore(mode: merge)`: the newer copy of each entry
///    wins, deletions recorded as tombstones win over older entries);
/// 5. writes the merged data back, encrypted, unless the file holds it
///    already; a [BackupSyncSection] adds what the file's copy keeps for
///    other devices (the history older than this device keeps it, see
///    `HistoryBackupSection`). `PUT` with `If-Match` (the ETag it read), or
///    `If-None-Match: *` when there was no file. When another device
///    wrote in between (`412`), it starts over, at most [maxAttempts]
///    times.
///
/// Sections the file holds that this device does not sync (not chosen
/// here, or unknown to this version) are written back unchanged. The
/// server stores only ciphertext: it sees the file's size and when it
/// changes.
class SyncEngine {
  new({required this.registry, this.codec = const BackupCodec()});

  final BackupRegistry registry;
  final BackupCodec codec;

  /// How often a run starts over after another device wrote the file in
  /// between.
  static const maxAttempts = 3;

  /// Syncs [config]'s sections through [dav] with [key].
  ///
  /// [cursor] is the last run's ([SyncRun.cursor]). With [onlyIfChanged]
  /// (a run after a change in the app), a run with nothing changed here
  /// since [cursor] returns [SyncRun.skipped] without a request. [newKey]
  /// writes the file with another key (a new passphrase), even when
  /// nothing changed. [prefetched] is the file as just read (setup).
  /// [cancelled] is asked before this device's data is changed and before
  /// the file is written: once it says yes, the run stops there and
  /// returns [SyncRun.skipped] (sync was turned off meanwhile).
  ///
  /// Throws a [SyncException].
  Future<SyncRun> run({
    required WebDavClient dav,
    required BackupKey key,
    required SyncConfig config,
    SyncCursor? cursor,
    BackupKey? newKey,
    bool onlyIfChanged = false,
    WebDavDownload? prefetched,
    bool Function()? cancelled,
  }) async {
    bool stop() => cancelled?.call() ?? false;
    final ids = config.syncedOf(registry.sections.map((s) => s.id));
    var last = cursor;
    var pending = prefetched;
    for (var attempt = 1; ; attempt++) {
      final local = await _export(ids, includeSecrets: config.syncsSecrets);
      final localPrint = fingerprint(local.sections);
      final changedHere = last?.fingerprint != localPrint || newKey != null;
      if (onlyIfChanged && !changedHere && attempt == 1) {
        return SyncRun.skipped(last);
      }

      final download =
          pending ??
          await _webDav(
            () => dav.download(
              SyncConfig.fileName,
              ifNoneMatch: changedHere ? null : last?.etag,
            ),
          );
      pending = null;
      if (download is WebDavUnchanged) {
        return SyncRun(result: SyncResult.unchanged, cursor: last);
      }

      BackupSnapshot? remote;
      String? etag;
      if (download case WebDavFile(:final bytes, etag: final fileEtag)) {
        remote = await _open(bytes, key);
        _checkVersions(remote, ids);
        // A browser hides the header unless the server exposes it (CORS).
        etag = fileEtag ?? await _webDav(() => dav.etagOf(SyncConfig.fileName));
      }
      final remotePrint = remote == null
          ? null
          : fingerprint(_only(remote.sections, ids));

      var merged = local;
      var mergedPrint = localPrint;
      BackupRestoreReport? report;
      // Nothing new from the server when the file holds what this device
      // last synced (its own write, or what it merged then).
      final newThere = remotePrint != last?.fileFingerprint;
      if (remote != null && remotePrint != localPrint && newThere) {
        if (stop()) return SyncRun.skipped(cursor);
        try {
          report = await registry.restore(
            remote,
            mode: BackupRestoreMode.merge,
            only: ids,
          );
        } on Object catch (error, stackTrace) {
          Error.throwWithStackTrace(
            SyncException(SyncFailure.localData, cause: error),
            stackTrace,
          );
        }
        merged = await _export(ids, includeSecrets: config.syncsSecrets);
        mergedPrint = fingerprint(merged.sections);
      }
      final received = mergedPrint != localPrint;

      final upload = BackupSnapshot(
        createdAt: merged.createdAt,
        appVersion: merged.appVersion,
        sections: {
          if (remote != null)
            for (final MapEntry(:key, :value) in remote.sections.entries)
              if (!ids.contains(key)) key: value,
          ...await _forFile(merged.sections, remote?.sections),
        },
      );
      final uploadPrint = fingerprint(_only(upload.sections, ids));
      SyncCursor cursorFor(String filePrint, String? fileEtag) => SyncCursor(
        fingerprint: mergedPrint,
        etag: fileEtag,
        remoteFingerprint: filePrint == mergedPrint ? null : filePrint,
      );

      if (newKey == null && remotePrint == uploadPrint) {
        return SyncRun(
          result: received ? SyncResult.received : SyncResult.unchanged,
          cursor: cursorFor(uploadPrint, etag),
          report: report,
        );
      }

      if (stop()) return SyncRun.skipped(cursor);
      final bytes = await codec.encryptWithKey(upload, newKey ?? key);
      try {
        final written = await dav.upload(
          SyncConfig.fileName,
          bytes,
          ifMatch: etag,
          // A file without an ETag (a server that keeps none) can only be
          // replaced as it is.
          unconditional: remote != null && etag == null,
        );
        return SyncRun(
          result: received ? SyncResult.exchanged : SyncResult.sent,
          cursor: cursorFor(uploadPrint, written),
          report: report,
        );
      } on WebDavException catch (error, stackTrace) {
        if (error.failure == WebDavFailure.conflict && attempt < maxAttempts) {
          // Another device wrote in between: read its file and merge again.
          last = null;
          continue;
        }
        Error.throwWithStackTrace(SyncException.fromWebDav(error), stackTrace);
      }
    }
  }

  /// The snapshot of the file [bytes] for [key]. Throws a
  /// [SyncException]: [SyncFailure.passphraseChanged] when the file was
  /// written with another key, [SyncFailure.damaged] when it does not
  /// open, [SyncFailure.notSyncFile] or [SyncFailure.newerVersion].
  Future<BackupSnapshot> _open(Uint8List bytes, BackupKey key) async {
    try {
      if (!codec.isEncryptedWith(bytes, key)) {
        throw const SyncException(SyncFailure.passphraseChanged);
      }
      return await codec.decryptWithKey(bytes, key);
    } on BackupPassphraseException {
      throw const SyncException(SyncFailure.damaged);
    } on BackupFormatException catch (error) {
      throw SyncException(
        error.newerVersion ? SyncFailure.newerVersion : SyncFailure.notSyncFile,
      );
    }
  }

  /// Throws [SyncFailure.newerVersion] when [remote] holds one of [ids] in
  /// a version newer than this app's section writes: merging it would
  /// lose what this version can't read.
  void _checkVersions(BackupSnapshot remote, Set<String> ids) {
    for (final id in ids) {
      final theirs = remote.sections[id]?.version;
      final ours = registry.section(id)?.version;
      if (theirs != null && ours != null && theirs > ours) {
        throw const SyncException(SyncFailure.newerVersion);
      }
    }
  }

  /// This device's [sections] as the file keeps them: what a
  /// [BackupSyncSection] adds of the file's copy ([remote]) for other
  /// devices, the others as they are.
  Future<Map<String, BackupSectionData>> _forFile(
    Map<String, BackupSectionData> sections,
    Map<String, BackupSectionData>? remote,
  ) async {
    final result = <String, BackupSectionData>{};
    for (final MapEntry(:key, :value) in sections.entries) {
      if (registry.section(key) case final BackupSyncSection section) {
        final theirs = remote?[key];
        try {
          result[key] = BackupSectionData(
            version: value.version,
            data: await section.syncData(
              value.data,
              remote: theirs?.data,
              remoteVersion: theirs?.version,
            ),
          );
        } on Object catch (error, stackTrace) {
          Error.throwWithStackTrace(
            SyncException(SyncFailure.localData, cause: error),
            stackTrace,
          );
        }
      } else {
        result[key] = value;
      }
    }
    return result;
  }

  Future<BackupSnapshot> _export(
    Set<String> ids, {
    required bool includeSecrets,
  }) async {
    try {
      return await registry.snapshot(includeSecrets: includeSecrets, only: ids);
    } on Object catch (error, stackTrace) {
      Error.throwWithStackTrace(
        SyncException(SyncFailure.localData, cause: error),
        stackTrace,
      );
    }
  }

  static Map<String, BackupSectionData> _only(
    Map<String, BackupSectionData> sections,
    Set<String> ids,
  ) => {
    for (final MapEntry(:key, :value) in sections.entries)
      if (ids.contains(key)) key: value,
  };

  static Future<T> _webDav<T>(Future<T> Function() request) async {
    try {
      return await request();
    } on WebDavException catch (error, stackTrace) {
      Error.throwWithStackTrace(SyncException.fromWebDav(error), stackTrace);
    }
  }

  /// SHA-256 (hex) of [sections] as canonical JSON (keys sorted at every
  /// level), so the same data always has the same fingerprint, however
  /// its maps were built.
  static String fingerprint(Map<String, BackupSectionData> sections) {
    final json = _canonical({
      for (final MapEntry(:key, :value) in sections.entries)
        key: value.toJson(),
    });
    final digest = const DartSha256().hashSync(utf8.encode(jsonEncode(json)));
    return [
      for (final byte in digest.bytes) byte.toRadixString(16).padLeft(2, '0'),
    ].join();
  }

  static Object? _canonical(Object? value) => switch (value) {
    final Map<Object?, Object?> map => {
      for (final MapEntry(:key, :value)
          in map.entries.toList()
            ..sort((a, b) => '${a.key}'.compareTo('${b.key}')))
        '$key': _canonical(value),
    },
    final List<Object?> list => [for (final item in list) _canonical(item)],
    _ => value,
  };
}
