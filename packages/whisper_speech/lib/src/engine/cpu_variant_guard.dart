import 'dart:convert';
import 'dart:io';

import 'package:meta/meta.dart';
import 'package:path/path.dart' as p;

/// What [CpuVariantGuard] remembers: the faster library builds it turned
/// off after a crash ([skipped]) and those that worked ([verified], with
/// the engine version they worked with).
@immutable
final class CpuVariantState {
  const new({this.skipped = const {}, this.verified = const {}});

  /// Tolerant counterpart of [toJson]: [empty] for anything invalid.
  factory fromJson(Object? json) {
    if (json is! Map<String, Object?> || json['schemaVersion'] != 1) {
      return empty;
    }
    final skipped = json['skipped'];
    final verified = json['verified'];
    return CpuVariantState(
      skipped: {
        if (skipped is List<Object?>)
          for (final name in skipped)
            if (name is String) name,
      },
      verified: {
        if (verified is Map<String, Object?>)
          for (final MapEntry(:key, :value) in verified.entries)
            if (value is String) key: value,
      },
    );
  }

  /// Nothing remembered.
  static const empty = CpuVariantState();

  /// Library names that crashed the app; never opened again.
  final Set<String> skipped;

  /// Library names that ran a first call, with the engine version (the
  /// library's own report) they ran it with.
  final Map<String, String> verified;

  Map<String, Object?> toJson() => {
    'schemaVersion': 1,
    'skipped': [...skipped]..sort(),
    'verified': verified,
  };
}

/// A guard against a faster build of the native library ([variants], e.g.
/// `libmozhi_whisper_i8mm.so`) crashing the app: a phone that misreports its
/// CPU features in `/proc/cpuinfo` would otherwise die with an illegal
/// instruction every time the engine starts, before the app can react.
///
/// * Before a variant is opened, and before its first real computation (a
///   transcription or a speech detection), each engine isolate writes a
///   marker file of its own ([arm], one role per isolate) naming the
///   library and this process; it removes it once that step succeeded
///   ([disarm]). After the
///   first successful computation the library is [CpuVariantState.verified]
///   for its version and no marker is written for it again.
/// * A marker of another process found when the engine starts
///   ([candidates]) means that process died in such a step: the library is
///   [CpuVariantState.skipped] from then on, and the next candidate (in
///   the end the baseline, which every CPU runs) is used.
/// * Only [variants] are guarded: the baseline, an explicit library path
///   and `$WHISPER_LIBRARY_PATH` are never armed or skipped.
///
/// Everything lives in [directory] (the app's support directory):
/// `<name>_cpu_variants.json` and `<name>_cpu_variant.<role>.marker`. All
/// methods are synchronous (the engine isolate calls them) and never
/// throw: a file system error leaves the guard without effect.
@immutable
final class CpuVariantGuard {
  const new({
    required this.directory,
    required this.variants,
    this.name = 'whisper',
    this.processId,
  });

  /// Where the state and the markers are kept.
  final String directory;

  /// The library names that are guarded (the non-baseline builds).
  final Set<String> variants;

  /// Prefix of the files (one guard per engine library).
  final String name;

  /// This process's id ([pid] when null; tests set another one).
  final int? processId;

  int get _pid => processId ?? pid;

  File get _stateFile => File(p.join(directory, '${name}_cpu_variants.json'));

  File _marker(String role) =>
      File(p.join(directory, '${name}_cpu_variant.$role.marker'));

  /// What is remembered.
  CpuVariantState read() {
    try {
      final file = _stateFile;
      if (!file.existsSync()) return CpuVariantState.empty;
      return CpuVariantState.fromJson(jsonDecode(file.readAsStringSync()));
    } on Object {
      return CpuVariantState.empty;
    }
  }

  /// [libraries] (best first) without the skipped variants. Markers left
  /// by another process are turned into skipped variants first (and
  /// deleted).
  List<String> candidates(List<String> libraries) {
    final skipped = _collectCrashes();
    return [
      for (final library in libraries)
        if (!skipped.contains(library)) library,
    ];
  }

  /// Whether [library] is guarded and has not run a first computation with
  /// engine [version] yet (null: any version).
  bool needsCheck(String library, {String? version}) {
    if (!variants.contains(library)) return false;
    final verified = read().verified[library];
    return verified == null || (version != null && verified != version);
  }

  /// Writes the marker of [role] (e.g. `open`, `compute`) for [library]
  /// when it is guarded.
  void arm(String library, {required String role}) {
    if (!variants.contains(library)) return;
    try {
      Directory(directory).createSync(recursive: true);
      _marker(role).writeAsStringSync(
        jsonEncode({'library': library, 'pid': _pid}),
        flush: true,
      );
    } on Object {
      // Without the marker the guard cannot help; the engine still runs.
    }
  }

  /// Removes the marker of [role]; with [verifiedVersion] (after the first
  /// successful computation) records [library] as working with that
  /// engine version.
  void disarm({
    required String role,
    String? library,
    String? verifiedVersion,
  }) {
    try {
      final marker = _marker(role);
      if (marker.existsSync()) marker.deleteSync();
    } on Object {
      // Left for the next start, which skips the variant: a slower engine,
      // never a crash.
    }
    if (library == null ||
        verifiedVersion == null ||
        !variants.contains(library)) {
      return;
    }
    final state = read();
    if (state.verified[library] == verifiedVersion) return;
    _write(
      CpuVariantState(
        skipped: state.skipped,
        verified: {...state.verified, library: verifiedVersion},
      ),
    );
  }

  /// The libraries of markers another process left (it died in a guarded
  /// step), merged into the skipped ones; the markers are deleted.
  Set<String> _collectCrashes() {
    final state = read();
    final crashed = <String>{};
    try {
      final folder = Directory(directory);
      if (folder.existsSync()) {
        for (final entry in folder.listSync()) {
          final file = p.basename(entry.path);
          if (entry is! File ||
              !file.startsWith('${name}_cpu_variant.') ||
              !file.endsWith('.marker')) {
            continue;
          }
          final marker = _readMarker(entry);
          // This process's own marker: a step that is running now.
          if (marker != null && marker.pid == _pid) continue;
          if (marker != null && variants.contains(marker.library)) {
            crashed.add(marker.library);
          }
          try {
            entry.deleteSync();
          } on Object {
            // Read again next time; the variant is skipped anyway.
          }
        }
      }
    } on Object {
      // The folder cannot be read: what is known already.
    }
    if (crashed.difference(state.skipped).isEmpty) return state.skipped;
    final skipped = {...state.skipped, ...crashed};
    _write(
      CpuVariantState(
        skipped: skipped,
        verified: {
          for (final MapEntry(:key, :value) in state.verified.entries)
            if (!crashed.contains(key)) key: value,
        },
      ),
    );
    return skipped;
  }

  static ({String library, int pid})? _readMarker(File file) {
    try {
      final json = jsonDecode(file.readAsStringSync());
      if (json is! Map<String, Object?>) return null;
      final library = json['library'];
      final pid = json['pid'];
      if (library is! String || pid is! int) return null;
      return (library: library, pid: pid);
    } on Object {
      return null;
    }
  }

  void _write(CpuVariantState state) {
    try {
      Directory(directory).createSync(recursive: true);
      final file = _stateFile;
      File('${file.path}.$_pid.tmp')
        ..writeAsStringSync(jsonEncode(state.toJson()), flush: true)
        ..renameSync(file.path);
    } on Object {
      // Not remembered: the markers say it again next time.
    }
  }
}
