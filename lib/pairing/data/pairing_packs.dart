import 'dart:convert';
import 'dart:io';

import 'package:flutter/foundation.dart';
import 'package:mozhi/backup/data/backup_registry.dart';
import 'package:mozhi/backup/sections/settings_backup_section.dart';
import 'package:mozhi/pairing/models/pairing_item.dart';

/// Reads one file of an outgoing item, from the start.
typedef PairingFileReader = Stream<List<int>> Function();

/// An item this phone can send: the [item] it offers and a reader for
/// each of its files (by [PairingFile.name]). Only these files are ever
/// read for the other phone, whatever it asks for.
class PairingOutgoingItem {
  const new(this.item, this.readers, {this.language});

  final PairingItem item;
  final Map<String, PairingFileReader> readers;

  /// The app language the item is for (for its name on the screen); null
  /// when it is not a language's.
  final String? language;
}

/// One kind of offline files pairing can send and take (translation
/// models, speech models, text recognition data, dictionaries), over the
/// manager that installs them.
///
/// The receiving side never trusts the sender: [plan] lists the files from
/// this phone's own catalogue (sizes and hashes), the transfer checks
/// every file against them, and [install] goes through the manager's
/// import path, which checks them again.
abstract interface class PairingPacks {
  PairingItemKind get kind;

  /// The items installed on this phone that it can send.
  Future<List<PairingOutgoingItem>> outgoing();

  /// What this phone needs of the offered [item] (whose [PairingItem.kind]
  /// is [kind]).
  Future<PairingPlan> plan(PairingItem item);

  /// Installs [item] from [files]: the files of its [plan], verified, in a
  /// temporary folder, named like the plan's files.
  Future<PairingItemOutcome> install(PairingItem item, List<File> files);
}

/// What the phone can send and take: the backup sections of [backup] and
/// the offline files of [packs] (one per kind). Either can be missing (the
/// web app, tests).
class PairingLibrary {
  new({this.backup, List<PairingPacks> packs = const []})
    : packs = {for (final kind in packs) kind.kind: kind};

  final BackupRegistry? backup;
  final Map<PairingItemKind, PairingPacks> packs;

  /// Every offline item this phone can send, kind by kind.
  Future<List<PairingOutgoingItem>> outgoingPacks() async => [
    for (final kind in packs.values) ...await _quietly(kind.outgoing),
  ];

  /// What this phone needs of [item].
  Future<PairingPlan> plan(PairingItem item) async {
    if (item.kind == PairingItemKind.data) {
      return backup == null
          ? const PairingPlan.incompatible()
          : PairingBackupItem.plan(item);
    }
    final kind = packs[item.kind];
    if (kind == null) return const PairingPlan.incompatible();
    try {
      return await kind.plan(item);
    } on Object {
      return const PairingPlan.incompatible();
    }
  }

  /// Installs [item] from its verified [files]; a data item is restored
  /// from its one file with [mode] (see [restore]).
  Future<PairingItemOutcome> install(
    PairingItem item,
    List<File> files, {
    required BackupRestoreMode mode,
  }) async {
    if (item.kind == PairingItemKind.data) {
      if (backup == null || files.length != 1) {
        return PairingItemOutcome.incompatible;
      }
      final Uint8List bytes;
      try {
        final file = files.single;
        if (await file.length() > PairingBackupItem.maxSize) {
          return PairingItemOutcome.damaged;
        }
        bytes = await file.readAsBytes();
      } on FileSystemException {
        return PairingItemOutcome.failed;
      }
      return await restore(item, bytes, mode: mode);
    }
    final kind = packs[item.kind];
    if (kind == null) return PairingItemOutcome.incompatible;
    try {
      return await kind.install(item, files);
    } on Object catch (error) {
      return pairingOutcomeOf(error);
    }
  }

  /// Restores the data item [item] from its verified [bytes] (the
  /// receiving phone keeps them in memory) with [mode]: only the sections
  /// the offer listed (see [PairingBackupItem.restore]).
  Future<PairingItemOutcome> restore(
    PairingItem item,
    Uint8List bytes, {
    required BackupRestoreMode mode,
  }) async {
    final registry = backup;
    if (registry == null || item.kind != PairingItemKind.data) {
      return PairingItemOutcome.incompatible;
    }
    return await PairingBackupItem.restore(registry, item, bytes, mode: mode);
  }

  static Future<List<PairingOutgoingItem>> _quietly(
    Future<List<PairingOutgoingItem>> Function() list,
  ) async {
    try {
      return await list();
    } on Object {
      // A kind that cannot list its files offers nothing.
      return const [];
    }
  }
}

/// The data item: a [BackupSnapshot] as JSON in one file
/// ([fileName]).
abstract final class PairingBackupItem {
  /// The [PairingItem.key] of the data item.
  static const key = 'backup';

  /// Its [PairingItem.id].
  static const id = 'data:$key';

  /// Its one file.
  static const fileName = 'backup.json';

  /// The largest backup a phone takes (64 MiB; a full history is a few).
  static const int maxSize = 64 << 20;

  /// The snapshot of [sections] (with secrets when [includeSecrets]) as
  /// an outgoing item.
  static Future<PairingOutgoingItem> outgoing(
    BackupRegistry registry, {
    required Set<String> sections,
    required bool includeSecrets,
  }) async {
    final snapshot = await registry.snapshot(
      includeSecrets: includeSecrets,
      only: sections,
    );
    final bytes = snapshotBytes(snapshot);
    return PairingOutgoingItem(
      PairingItem(
        kind: PairingItemKind.data,
        key: key,
        files: [PairingFile(name: fileName, size: bytes.length)],
        sections: [...snapshot.sections.keys],
        secrets: includeSecrets,
      ),
      {fileName: () => Stream.value(bytes)},
    );
  }

  /// The UTF-8 JSON of [snapshot].
  static List<int> snapshotBytes(BackupSnapshot snapshot) =>
      utf8.encode(jsonEncode(snapshot.toJson()));

  /// The data item is taken when it is one [fileName] of at most
  /// [maxSize] bytes.
  static PairingPlan plan(PairingItem item) {
    final file = item.file(fileName);
    if (item.files.length != 1 || file == null || file.size > maxSize) {
      return const PairingPlan.incompatible();
    }
    return PairingPlan.available([
      PairingFile(name: fileName, size: file.size),
    ]);
  }

  /// Restores the snapshot in [bytes] (UTF-8 JSON, the file of [item])
  /// into [registry] with [mode].
  ///
  /// Only what the receiving phone showed is restored: the sections the
  /// offer listed ([PairingItem.sections]). A snapshot that holds any
  /// other section, or secrets when the offer said it has none
  /// ([PairingItem.secrets]), is [PairingItemOutcome.damaged] and nothing
  /// of it is restored. The JSON is parsed on a background isolate (in a
  /// browser, where nothing is received, on the same one).
  static Future<PairingItemOutcome> restore(
    BackupRegistry registry,
    PairingItem item,
    Uint8List bytes, {
    required BackupRestoreMode mode,
  }) async {
    if (bytes.length > maxSize) return PairingItemOutcome.damaged;
    final (snapshot, failure) = await compute(_parse, bytes);
    if (snapshot == null) return failure ?? PairingItemOutcome.damaged;
    final offered = item.sections.toSet();
    if (!snapshot.sections.keys.every(offered.contains)) {
      return PairingItemOutcome.damaged;
    }
    final settings = snapshot.sections[SettingsBackupSection.sectionId];
    if (!item.secrets && SettingsBackupSection.hasSecrets(settings?.data)) {
      return PairingItemOutcome.damaged;
    }
    try {
      await registry.restore(snapshot, mode: mode, only: offered);
      return PairingItemOutcome.installed;
    } on Object catch (error) {
      return pairingOutcomeOf(error);
    }
  }

  /// The snapshot in [bytes], or why there is none.
  static (BackupSnapshot?, PairingItemOutcome?) _parse(Uint8List bytes) {
    try {
      final json = jsonDecode(utf8.decode(bytes));
      if (json is! Map<String, Object?>) {
        return (null, PairingItemOutcome.damaged);
      }
      return (BackupSnapshot.fromJson(json), null);
    } on BackupSnapshotVersionException {
      return (null, PairingItemOutcome.incompatible);
    } on Object {
      // Not UTF-8, not JSON, not a snapshot, or JSON nested too deeply.
      return (null, PairingItemOutcome.damaged);
    }
  }
}

/// The outcome for an install that threw [error]: [PairingItemOutcome
/// .noSpace] for a full disk, else [PairingItemOutcome.failed].
PairingItemOutcome pairingOutcomeOf(Object error) {
  final cause = switch (error) {
    BackupSectionException(:final cause) => cause,
    _ => error,
  };
  return isNoSpace(cause)
      ? PairingItemOutcome.noSpace
      : PairingItemOutcome.failed;
}

/// Whether [error] says the storage is full (`ENOSPC`).
bool isNoSpace(Object? error) =>
    error is FileSystemException && error.osError?.errorCode == _enospc;

const _enospc = 28;

/// Whether [item] offers [expected]: a file of that name and size, and of
/// the same SHA-256 and SHA-1 when both sides know them.
bool matchesOffer(PairingItem item, PairingFile expected) {
  final offered = item.file(expected.name);
  if (offered == null || offered.size != expected.size) return false;
  bool same(String? a, String? b) => a == null || b == null || a == b;
  return same(offered.sha256, expected.sha256) &&
      same(offered.sha1, expected.sha1);
}
