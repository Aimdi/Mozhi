import 'dart:convert';
import 'dart:io';

import 'package:meta/meta.dart';
import 'package:path/path.dart' as p;

/// A crash of a library recorded by [CpuVariantGuard]: how many guarded
/// steps in a row died with it (`count`), and the id of the process that
/// died last (`pid`; the same process found again is not counted twice).
typedef CpuVariantCrashes = ({int count, int pid});

/// What [CpuVariantGuard] remembers: the faster library builds it turned
/// off after crashes ([skipped]), those that crashed but get another try
/// ([crashes]) and those that worked ([verified], with the engine version
/// they worked with).
@immutable
final class CpuVariantState {
  const new({
    this.skipped = const {},
    this.verified = const {},
    this.crashes = const {},
  });

  /// Tolerant counterpart of [toJson]: [empty] for anything invalid, and
  /// invalid entries are left out.
  factory fromJson(Object? json) {
    if (json is! Map<String, Object?> || json['schemaVersion'] != 1) {
      return empty;
    }
    final skipped = json['skipped'];
    final verified = json['verified'];
    final crashes = json['crashes'];
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
      crashes: {
        if (crashes is Map<String, Object?>)
          for (final MapEntry(:key, :value) in crashes.entries)
            if (value case {'count': final int count, 'pid': final int pid}
                when count > 0)
              key: (count: count, pid: pid),
      },
    );
  }

  /// Nothing remembered.
  static const empty = CpuVariantState();

  /// Library names that crashed the app [CpuVariantGuard.crashLimit] times
  /// in a row; never opened again.
  final Set<String> skipped;

  /// Library names that ran a first call, with the engine version (the
  /// library's own report) they ran it with.
  final Map<String, String> verified;

  /// Library names that crashed the app fewer than
  /// [CpuVariantGuard.crashLimit] times in a row (since they last ran a
  /// first call): still opened, and guarded again until they ran one.
  final Map<String, CpuVariantCrashes> crashes;

  Map<String, Object?> toJson() => {
    'schemaVersion': 1,
    'skipped': [...skipped]..sort(),
    'verified': {
      for (final key in [...verified.keys]..sort()) key: verified[key],
    },
    'crashes': {
      for (final key in [...crashes.keys]..sort())
        key: {'count': crashes[key]!.count, 'pid': crashes[key]!.pid},
    },
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
///   ([candidates]) means that process died in such a step: a crash of the
///   library ([CpuVariantState.crashes], which also drops its
///   verification). After [crashLimit] crashes in a row, with no
///   successful first computation in between, the library is
///   [CpuVariantState.skipped] from then on, and the next candidate (in
///   the end the baseline, which every CPU runs) is used. A successful
///   first computation clears the count.
/// * Only [variants] are guarded: the baseline, an explicit library path
///   and `$WHISPER_LIBRARY_PATH` are never armed or skipped.
///
/// Everything lives in [directory] (the app's support directory):
/// `<name>_cpu_variants.json` and `<name>_cpu_variant.<role>.marker`. All
/// methods are synchronous (the engine isolate calls them) and never
/// throw: a file system error leaves the guard without effect. Only
/// [variants] are read from the state file (other names are ignored), so
/// it stays a few hundred bytes; a damaged or oversized one counts as
/// empty, and [candidates] writes it again as the guard reads it.
@immutable
final class CpuVariantGuard {
  const new({
    required this.directory,
    required this.variants,
    this.name = 'whisper',
    this.processId,
  });

  /// Crashes in a row after which a variant is skipped for good.
  ///
  /// Not one: the process may have died for another reason while the
  /// marker was there (the low-memory killer, a force stop, a reboot for
  /// an update), and that must not turn a working faster build off for
  /// good. A variant that the CPU really can't run dies with an illegal
  /// instruction on every try, so waiting for the second crash costs such
  /// a phone one extra crash at most; two unrelated kills in a row in the
  /// short guarded steps, with no successful first computation between
  /// them, still turn a working build off (the slower baseline then runs).
  static const crashLimit = 2;

  /// Largest state file that is read (a valid one is far smaller).
  static const int _maxStateBytes = 16 * 1024;

  /// Largest marker that is read (a valid one is a few dozen bytes).
  static const _maxMarkerBytes = 1024;

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

  /// What is remembered about [variants] (nothing about other names).
  CpuVariantState read() => _load().state;

  /// [libraries] (best first) without the skipped variants. Markers left
  /// by another process are counted as crashes first (and deleted), and a
  /// damaged state file is written again.
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
  /// engine version, which clears its crashes.
  void disarm({
    required String role,
    String? library,
    String? verifiedVersion,
  }) {
    try {
      final marker = _marker(role);
      if (marker.existsSync()) marker.deleteSync();
    } on Object {
      // Left for the next start, which counts a crash: at worst, in the
      // end, a slower engine, never a crash.
    }
    if (library == null ||
        verifiedVersion == null ||
        !variants.contains(library)) {
      return;
    }
    final state = read();
    // Verified (a crash drops it), or turned off already: nothing to do.
    if (state.verified[library] == verifiedVersion ||
        state.skipped.contains(library)) {
      return;
    }
    _write(
      CpuVariantState(
        skipped: state.skipped,
        verified: {...state.verified, library: verifiedVersion},
        crashes: {
          for (final MapEntry(:key, :value) in state.crashes.entries)
            if (key != library) key: value,
        },
      ),
    );
  }

  /// The state file as the guard reads it: only [variants], and each
  /// library in one of skipped (also when its crashes reached
  /// [crashLimit]), crashed (not verified) or verified. With `rewrite`
  /// when the file is not exactly what [_write] would write for it
  /// (damaged, too large, other names); not when it cannot be read at all
  /// (it may be fine).
  ({CpuVariantState state, bool rewrite}) _load() {
    final file = _stateFile;
    try {
      if (!file.existsSync()) {
        return (state: CpuVariantState.empty, rewrite: false);
      }
      if (file.lengthSync() > _maxStateBytes) {
        return (state: CpuVariantState.empty, rewrite: true);
      }
      final text = utf8.decode(file.readAsBytesSync());
      final state = _known(CpuVariantState.fromJson(jsonDecode(text)));
      return (state: state, rewrite: jsonEncode(state.toJson()) != text);
      // coverage:ignore-start
    } on FileSystemException {
      // Not readable now (it may be fine): not replaced.
      return (state: CpuVariantState.empty, rewrite: false);
      // coverage:ignore-end
    } on Object {
      // Damaged (not UTF-8 or not JSON).
      return (state: CpuVariantState.empty, rewrite: true);
    }
  }

  /// [state] restricted to [variants], each library in one place.
  CpuVariantState _known(CpuVariantState state) {
    final skipped = {
      for (final library in state.skipped)
        if (variants.contains(library)) library,
      for (final MapEntry(:key, :value) in state.crashes.entries)
        if (variants.contains(key) && value.count >= crashLimit) key,
    };
    final crashes = {
      for (final MapEntry(:key, :value) in state.crashes.entries)
        if (variants.contains(key) && !skipped.contains(key)) key: value,
    };
    return CpuVariantState(
      skipped: skipped,
      crashes: crashes,
      verified: {
        for (final MapEntry(:key, :value) in state.verified.entries)
          if (variants.contains(key) &&
              !skipped.contains(key) &&
              !crashes.containsKey(key))
            key: value,
      },
    );
  }

  /// The markers another process left (it died in a guarded step) counted
  /// as crashes of their libraries, the markers deleted; returns the
  /// skipped libraries.
  Set<String> _collectCrashes() {
    final (:state, :rewrite) = _load();
    // Library -> the process that died with it.
    final crashed = <String, int>{};
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
            crashed.putIfAbsent(marker.library, () => marker.pid);
          }
          try {
            entry.deleteSync();
          } on Object {
            // Read again next time; counted once (same process).
          }
        }
      }
    } on Object {
      // The folder cannot be read: what is known already.
    }
    final next = _withCrashes(state, crashed);
    if (identical(next, state) && !rewrite) return state.skipped;
    _write(next);
    return next.skipped;
  }

  /// [state] after the processes in [crashed] died with those libraries
  /// ([state] itself when that changes nothing).
  static CpuVariantState _withCrashes(
    CpuVariantState state,
    Map<String, int> crashed,
  ) {
    final skipped = {...state.skipped};
    final verified = {...state.verified};
    final crashes = {...state.crashes};
    var changed = false;
    for (final MapEntry(key: library, value: pid) in crashed.entries) {
      final last = crashes[library];
      // Turned off already, or this process's crash was counted already
      // (another engine isolate of this start found its marker first).
      if (skipped.contains(library) || last?.pid == pid) continue;
      changed = true;
      verified.remove(library);
      final count = (last?.count ?? 0) + 1;
      if (count >= crashLimit) {
        crashes.remove(library);
        skipped.add(library);
      } else {
        crashes[library] = (count: count, pid: pid);
      }
    }
    if (!changed) return state;
    return CpuVariantState(
      skipped: skipped,
      verified: verified,
      crashes: crashes,
    );
  }

  static ({String library, int pid})? _readMarker(File file) {
    try {
      if (file.lengthSync() > _maxMarkerBytes) return null;
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
