import 'dart:async';

import 'package:equatable/equatable.dart';
import 'package:mozhi/backup/models/backup_section.dart';
import 'package:mozhi/backup/models/backup_snapshot.dart';
import 'package:package_info_plus/package_info_plus.dart';

export '../models/backup_section.dart';
export '../models/backup_snapshot.dart';

/// A [BackupSection] failed while [BackupRegistry.snapshot] exported it or
/// [BackupRegistry.restore] restored it.
class BackupSectionException implements Exception {
  const new(this.sectionId, this.cause);

  /// The [BackupSection.id] of the section that failed.
  final String sectionId;

  /// What the section threw.
  final Object cause;

  // The cause is left out: it may quote the data.
  @override
  String toString() => 'BackupSectionException($sectionId)';
}

/// How many items of a section there were before and after a restore (see
/// [BackupItemCounter]).
class BackupItemChange extends Equatable {
  const new({required this.before, required this.after});

  final int before;
  final int after;

  @override
  List<Object?> get props => [before, after];
}

/// What [BackupRegistry.restore] did.
class BackupRestoreReport extends Equatable {
  const new({
    required this.restored,
    this.skipped = const [],
    this.changes = const {},
  });

  /// Ids of the sections that were restored, in the registry's order.
  final List<String> restored;

  /// Ids of sections in the snapshot that this app has no section for (a
  /// newer version or another build wrote them); they were left alone.
  final List<String> skipped;

  /// Item counts before and after, for restored sections that count them
  /// ([BackupItemCounter]).
  final Map<String, BackupItemChange> changes;

  @override
  List<Object?> get props => [restored, skipped, changes];
}

/// The [BackupSection]s of the app: every kind of data that backups, sync
/// and pairing carry. The app creates one (`bootstrap`) and provides it as
/// a `RepositoryProvider<BackupRegistry>`.
///
/// [snapshot] and [restore] run one at a time (a sync never runs halfway
/// through a restore). After each [restore], [restored] tells the app
/// which sections may hold new data, so that screens and cubits holding a
/// copy reload it (`BackupRestoreListener`).
///
/// `appVersion` (written into snapshots) defaults to the platform's
/// package info (`1.4.0+12`), `clock` to [DateTime.now].
class BackupRegistry {
  new({Future<String> Function()? appVersion, DateTime Function()? clock})
    : _appVersion = appVersion ?? platformAppVersion,
      _clock = clock ?? DateTime.now;

  final Future<String> Function() _appVersion;
  final DateTime Function() _clock;
  final _sections = <String, BackupSection>{};
  final _restored = StreamController<Set<String>>.broadcast();
  Future<void> _lock = Future.value();

  /// Registers [section]. Throws an [ArgumentError] when a section with its
  /// id is registered already.
  void register(BackupSection section) {
    if (_sections.containsKey(section.id)) {
      throw ArgumentError.value(section.id, 'section', 'already registered');
    }
    _sections[section.id] = section;
  }

  /// The registered sections, in the order they were registered.
  List<BackupSection> get sections => List.unmodifiable(_sections.values);

  /// The registered section [id], or null.
  BackupSection? section(String id) => _sections[id];

  /// After each [restore] (also one that failed): the ids of the sections
  /// it restored or tried to restore.
  Stream<Set<String>> get restored => _restored.stream;

  /// The data of every section (only those in [only], when given; unknown
  /// ids are ignored), with secrets when [includeSecrets].
  ///
  /// Throws a [BackupSectionException] naming the first section that
  /// failed.
  Future<BackupSnapshot> snapshot({
    required bool includeSecrets,
    Set<String>? only,
  }) => _synchronized(() async {
    final sections = <String, BackupSectionData>{};
    for (final section in _sections.values) {
      if (only != null && !only.contains(section.id)) continue;
      final Object? data;
      try {
        data = await section.export(includeSecrets: includeSecrets);
      } on Object catch (error, stackTrace) {
        Error.throwWithStackTrace(
          BackupSectionException(section.id, error),
          stackTrace,
        );
      }
      sections[section.id] = BackupSectionData(
        version: section.version,
        data: data,
      );
    }
    return BackupSnapshot(
      createdAt: _clock().toUtc(),
      appVersion: await _safeAppVersion(),
      sections: Map.unmodifiable(sections),
    );
  });

  /// Restores the sections of [snapshot] (only those in [only], when
  /// given) with [mode]; sections the snapshot doesn't hold are left
  /// alone.
  ///
  /// Section ids this registry doesn't know are skipped and listed in the
  /// report ([BackupRestoreReport.skipped]). Every section is attempted;
  /// the first failure is then rethrown as a [BackupSectionException].
  Future<BackupRestoreReport> restore(
    BackupSnapshot snapshot, {
    required BackupRestoreMode mode,
    Set<String>? only,
  }) => _synchronized(() async {
    final restored = <String>[];
    final attempted = <String>{};
    final changes = <String, BackupItemChange>{};
    final skipped = [
      for (final id in snapshot.sections.keys)
        if (!_sections.containsKey(id) && (only == null || only.contains(id)))
          id,
    ];
    // A list rather than a nullable local assigned in a catch (dart2js).
    final failures = <(BackupSectionException, StackTrace)>[];
    for (final section in _sections.values) {
      final data = snapshot.sections[section.id];
      if (data == null || (only != null && !only.contains(section.id))) {
        continue;
      }
      attempted.add(section.id);
      final counter = section is BackupItemCounter
          ? section as BackupItemCounter
          : null;
      final before = await _count(counter);
      try {
        await section.restore(data.data, version: data.version, mode: mode);
      } on Object catch (error, stackTrace) {
        failures.add((BackupSectionException(section.id, error), stackTrace));
        continue;
      }
      restored.add(section.id);
      final after = await _count(counter);
      if (before != null && after != null) {
        changes[section.id] = BackupItemChange(before: before, after: after);
      }
    }
    if (attempted.isNotEmpty) _restored.add(Set.unmodifiable(attempted));
    if (failures.firstOrNull case (final failure, final stackTrace)?) {
      Error.throwWithStackTrace(failure, stackTrace);
    }
    return BackupRestoreReport(
      restored: List.unmodifiable(restored),
      skipped: List.unmodifiable(skipped),
      changes: Map.unmodifiable(changes),
    );
  });

  /// Stops [restored].
  Future<void> dispose() => _restored.close();

  /// `version+buildNumber` of the running app (from its package info).
  static Future<String> platformAppVersion() async {
    final info = await PackageInfo.fromPlatform();
    return info.buildNumber.isEmpty
        ? info.version
        : '${info.version}+${info.buildNumber}';
  }

  /// What [counter] counts on this device; null without one, or when it
  /// fails (the restore itself is not affected).
  static Future<int?> _count(BackupItemCounter? counter) async {
    if (counter == null) return null;
    try {
      return await counter.countLocalItems();
    } on Object {
      return null;
    }
  }

  Future<String> _safeAppVersion() async {
    try {
      return await _appVersion();
    } on Object {
      return 'unknown';
    }
  }

  Future<T> _synchronized<T>(Future<T> Function() action) {
    final result = _lock.then((_) => action());
    _lock = result.then<void>((_) {}, onError: (Object _) {});
    return result;
  }
}
