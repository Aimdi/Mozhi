import 'dart:convert';
import 'dart:io';

import 'package:flutter_test/flutter_test.dart';
import 'package:path/path.dart' as p;
import 'package:whisper_speech/src/engine/cpu_variant_guard.dart';

const _i8mm = 'libmozhi_whisper_i8mm.so';
const _dotprod = 'libmozhi_whisper_dotprod.so';
const _baseline = 'libmozhi_whisper.so';
const List<String> _all = [_i8mm, _baseline];

void main() {
  late Directory root;

  setUp(() => root = Directory.systemTemp.createTempSync('whisper_guard_'));
  tearDown(() => root.deleteSync(recursive: true));

  CpuVariantGuard guard({int processId = 100, String? directory}) =>
      CpuVariantGuard(
        directory: directory ?? root.path,
        variants: const {_i8mm, _dotprod},
        processId: processId,
      );

  File marker(String role) =>
      File(p.join(root.path, 'whisper_cpu_variant.$role.marker'));

  File stateFile() => File(p.join(root.path, 'whisper_cpu_variants.json'));

  /// Process [processId] dies while [library] is armed for [role].
  void crash(int processId, {String library = _i8mm, String role = 'open'}) =>
      guard(processId: processId).arm(library, role: role);

  group(CpuVariantState, () {
    test('round-trips through JSON', () {
      const state = CpuVariantState(
        skipped: {_i8mm},
        verified: {_dotprod: 'v1'},
        crashes: {'other': (count: 1, pid: 7)},
      );
      final read = CpuVariantState.fromJson(
        jsonDecode(jsonEncode(state.toJson())),
      );
      expect(read.skipped, {_i8mm});
      expect(read.verified, {_dotprod: 'v1'});
      expect(read.crashes, {'other': (count: 1, pid: 7)});
    });

    test('writes its entries sorted', () {
      const state = CpuVariantState(
        verified: {'b': '1', 'a': '2'},
        crashes: {'d': (count: 1, pid: 1), 'c': (count: 1, pid: 2)},
      );
      final json = state.toJson();
      expect((json['verified']! as Map).keys, ['a', 'b']);
      expect((json['crashes']! as Map).keys, ['c', 'd']);
    });

    test('ignores what is invalid', () {
      expect(CpuVariantState.fromJson(null).skipped, isEmpty);
      expect(
        CpuVariantState.fromJson(const {'schemaVersion': 2}).verified,
        isEmpty,
      );
      final partly = CpuVariantState.fromJson(const {
        'schemaVersion': 1,
        'skipped': [_i8mm, 3],
        'verified': {_dotprod: 3, _i8mm: 'v'},
        'crashes': {
          'a': {'count': 1, 'pid': 2},
          'b': {'count': 0, 'pid': 2},
          'c': {'count': '1', 'pid': 2},
          'd': {'count': 1},
          'e': 1,
        },
      });
      expect(partly.skipped, {_i8mm});
      expect(partly.verified, {_i8mm: 'v'});
      expect(partly.crashes, {'a': (count: 1, pid: 2)});
      // Written before crashes were counted: none.
      expect(
        CpuVariantState.fromJson(const {'schemaVersion': 1}).crashes,
        isEmpty,
      );
    });
  });

  group(CpuVariantGuard, () {
    test('keeps every candidate while nothing crashed', () {
      expect(guard().candidates(_all), _all);
      expect(guard().read().skipped, isEmpty);
      // Nothing to remember: no file.
      expect(stateFile().existsSync(), isFalse);
    });

    test('one crash: the variant is tried once more', () {
      crash(1);
      expect(marker('open').existsSync(), isTrue);

      // The next start (another process) finds the marker.
      final next = guard(processId: 2);
      expect(next.candidates(_all), _all);
      expect(marker('open').existsSync(), isFalse);
      expect(next.read().skipped, isEmpty);
      expect(next.read().crashes, {_i8mm: (count: 1, pid: 1)});
      // Its first computation is guarded again.
      expect(next.needsCheck(_i8mm, version: 'v1'), isTrue);
      // Remembered without the marker, still not skipped.
      expect(guard(processId: 3).candidates(_all), _all);
      expect(guard().read().crashes, {_i8mm: (count: 1, pid: 1)});
    });

    test('two crashes in a row skip the variant for good', () {
      crash(1);
      expect(guard(processId: 2).candidates(_all), _all);
      // Tried again and died again, in its first computation this time.
      crash(2, role: 'compute');

      final next = guard(processId: 3);
      expect(next.candidates(_all), [_baseline]);
      expect(marker('compute').existsSync(), isFalse);
      expect(next.read().skipped, {_i8mm});
      expect(next.read().crashes, isEmpty);
      // Remembered without the marker.
      expect(guard(processId: 4).candidates(_all), [_baseline]);
      // A marker of it found later changes nothing.
      crash(4);
      expect(guard(processId: 5).candidates(_all), [_baseline]);
      expect(guard().read().skipped, {_i8mm});
    });

    test('a success after one crash verifies it and clears the count', () {
      crash(1);
      final retried = guard(processId: 2);
      expect(retried.candidates(_all), _all);
      retried
        ..arm(_i8mm, role: 'compute')
        ..disarm(role: 'compute', library: _i8mm, verifiedVersion: 'v1');
      expect(retried.read().verified, {_i8mm: 'v1'});
      expect(retried.read().crashes, isEmpty);
      expect(retried.needsCheck(_i8mm, version: 'v1'), isFalse);

      // Another kill later counts as the first one again.
      crash(2);
      expect(guard(processId: 3).candidates(_all), _all);
      expect(guard().read().crashes, {_i8mm: (count: 1, pid: 2)});
      expect(guard().read().skipped, isEmpty);
    });

    test('a failed first computation keeps the count', () {
      crash(1);
      guard(processId: 2)
        ..candidates(_all)
        ..arm(_i8mm, role: 'compute')
        // An engine error: no crash, but not verified either.
        ..disarm(role: 'compute', library: _i8mm);
      expect(guard().read().crashes, {_i8mm: (count: 1, pid: 1)});
      crash(2, role: 'compute');
      expect(guard(processId: 3).candidates(_all), [_baseline]);
    });

    test('counts each dead process once', () {
      // Both engine isolates of process 1 died with it.
      crash(1, role: 'compute-transcribe');
      crash(1, role: 'open-vad');
      expect(guard(processId: 2).candidates(_all), _all);
      expect(guard().read().crashes, {_i8mm: (count: 1, pid: 1)});

      // The other isolate of process 2 still finds a marker of process 1
      // (listed before the first one deleted it): the same crash.
      crash(1, role: 'open-vad');
      expect(guard(processId: 2).candidates(_all), _all);
      expect(guard().read().crashes, {_i8mm: (count: 1, pid: 1)});
    });

    test('counts each variant on its own', () {
      crash(1);
      crash(1, library: _dotprod, role: 'compute');
      expect(guard(processId: 2).candidates([_i8mm, _dotprod]), [
        _i8mm,
        _dotprod,
      ]);
      expect(guard().read().crashes.keys, unorderedEquals([_i8mm, _dotprod]));
      crash(2, library: _dotprod);
      expect(guard(processId: 3).candidates([_i8mm, _dotprod]), [_i8mm]);
      expect(guard().read().crashes, {_i8mm: (count: 1, pid: 1)});
      expect(guard().read().skipped, {_dotprod});
    });

    test('a marker of this process is a step that runs now', () {
      final current = guard(processId: 7)..arm(_i8mm, role: 'compute');
      expect(current.candidates(_all), _all);
      expect(marker('compute').existsSync(), isTrue);
      expect(current.read().crashes, isEmpty);
      current.disarm(role: 'compute');
      expect(marker('compute').existsSync(), isFalse);
    });

    test('a crash of a verified variant drops its verification', () {
      guard(processId: 1)
        ..arm(_i8mm, role: 'compute')
        ..disarm(role: 'compute', library: _i8mm, verifiedVersion: 'v1');
      expect(guard().read().verified, {_i8mm: 'v1'});
      expect(guard().needsCheck(_i8mm, version: 'v1'), isFalse);

      crash(1);
      expect(guard(processId: 2).candidates(_all), _all);
      expect(guard().read().verified, isEmpty);
      expect(guard().needsCheck(_i8mm, version: 'v1'), isTrue);
      expect(guard().read().crashes, {_i8mm: (count: 1, pid: 1)});
    });

    test('guards only its variants', () {
      final current = guard()..arm(_baseline, role: 'open');
      expect(marker('open').existsSync(), isFalse);
      expect(current.needsCheck(_baseline), isFalse);
      expect(current.needsCheck('/custom/libmozhi_whisper.so'), isFalse);
      current.disarm(role: 'open', library: _baseline, verifiedVersion: 'v1');
      expect(current.read().verified, isEmpty);

      // A marker naming something else is dropped without counting it.
      marker('open')
          .writeAsStringSync(jsonEncode({'library': _baseline, 'pid': 1}));
      expect(current.candidates(_all), _all);
      expect(marker('open').existsSync(), isFalse);
      expect(stateFile().existsSync(), isFalse);
    });

    test('needs a check until verified for the version', () {
      final current = guard();
      expect(current.needsCheck(_i8mm), isTrue);
      current.disarm(role: 'compute', library: _i8mm, verifiedVersion: 'v1');
      expect(current.needsCheck(_i8mm), isFalse);
      expect(current.needsCheck(_i8mm, version: 'v1'), isFalse);
      expect(current.needsCheck(_i8mm, version: 'v2'), isTrue);
      // The same version again writes nothing new.
      current.disarm(role: 'compute', library: _i8mm, verifiedVersion: 'v1');
      expect(current.read().verified, {_i8mm: 'v1'});
    });

    test('does not verify a variant that is turned off', () {
      stateFile().writeAsStringSync(
        jsonEncode(const CpuVariantState(skipped: {_i8mm}).toJson()),
      );
      guard().disarm(role: 'compute', library: _i8mm, verifiedVersion: 'v1');
      expect(guard().read().verified, isEmpty);
      expect(guard().read().skipped, {_i8mm});
    });

    test('drops damaged markers and state', () {
      marker('open').writeAsStringSync('{');
      File(p.join(root.path, 'whisper_cpu_variant.x.marker'))
          .writeAsStringSync(jsonEncode({'library': 3}));
      // Too large to be a marker, whatever it says.
      marker('big').writeAsStringSync(
        jsonEncode({'library': _i8mm, 'pid': 1, 'pad': 'x' * 2000}),
      );
      stateFile().writeAsStringSync('[');
      File(p.join(root.path, 'unrelated.marker')).writeAsStringSync('x');
      expect(guard().candidates(_all), _all);
      expect(marker('open').existsSync(), isFalse);
      expect(marker('big').existsSync(), isFalse);
      expect(File(p.join(root.path, 'unrelated.marker')).existsSync(), isTrue);
      expect(guard().read().skipped, isEmpty);
      expect(guard().read().crashes, isEmpty);
    });

    test('reads a damaged state as empty and writes it again', () {
      for (final damaged in [
        '[',
        '{"schemaVersion": 1, "skipped": ',
        '"text"',
        '{"schemaVersion": 3, "skipped": ["$_i8mm"]}',
      ]) {
        stateFile().writeAsStringSync(damaged);
        expect(guard().read().skipped, isEmpty, reason: damaged);
        // Reading alone changes nothing.
        expect(stateFile().readAsStringSync(), damaged);
        expect(guard().candidates(_all), _all);
        expect(
          jsonDecode(stateFile().readAsStringSync()),
          CpuVariantState.empty.toJson(),
          reason: damaged,
        );
      }
      stateFile().writeAsBytesSync([0xff, 0xfe, 0x7b]);
      expect(guard().read().skipped, isEmpty);
      expect(guard().candidates(_all), _all);
      expect(stateFile().readAsStringSync(), contains('schemaVersion'));
    });

    test('ignores libraries that are not its variants', () {
      stateFile().writeAsStringSync(
        jsonEncode({
          'schemaVersion': 1,
          'skipped': [_i8mm, _baseline, '../etc/passwd'],
          'verified': {_dotprod: 'v1', 'libother.so': 'v1'},
          'crashes': {
            'libother.so': {'count': 1, 'pid': 3},
          },
        }),
      );
      final state = guard().read();
      expect(state.skipped, {_i8mm});
      expect(state.verified, {_dotprod: 'v1'});
      expect(state.crashes, isEmpty);
      expect(guard().needsCheck('libother.so'), isFalse);

      // The next start writes only what it knows.
      expect(guard(processId: 2).candidates([..._all, _dotprod]), [
        _baseline,
        _dotprod,
      ]);
      final written = stateFile().readAsStringSync();
      expect(written, isNot(contains('libother.so')));
      expect(written, isNot(contains('passwd')));
      expect(written, jsonEncode(state.toJson()));
    });

    test('keeps each library in one place', () {
      stateFile().writeAsStringSync(
        jsonEncode({
          'schemaVersion': 1,
          'skipped': [_i8mm],
          // Turned off and verified: turned off.
          'verified': {_i8mm: 'v1', _dotprod: 'v1'},
          'crashes': {
            _i8mm: {'count': 1, 'pid': 3},
            // Crashed and verified: crashed.
            _dotprod: {'count': 1, 'pid': 3},
          },
        }),
      );
      var state = guard().read();
      expect(state.skipped, {_i8mm});
      expect(state.verified, isEmpty);
      expect(state.crashes, {_dotprod: (count: 1, pid: 3)});

      // Crashed as often as the limit: turned off.
      stateFile().writeAsStringSync(
        jsonEncode({
          'schemaVersion': 1,
          'crashes': {
            _dotprod: {'count': CpuVariantGuard.crashLimit, 'pid': 3},
          },
        }),
      );
      state = guard().read();
      expect(state.skipped, {_dotprod});
      expect(state.crashes, isEmpty);
    });

    test('reads a state that is too large as empty', () {
      final valid = jsonEncode(
        const CpuVariantState(skipped: {_i8mm}).toJson(),
      );
      stateFile().writeAsStringSync('$valid${' ' * (20 * 1024)}');
      expect(guard().read().skipped, isEmpty);
      expect(guard().candidates(_all), _all);
      expect(stateFile().lengthSync(), lessThan(200));
    });

    test('leaves a state that is as written alone', () {
      stateFile().writeAsStringSync(
        jsonEncode(
          const CpuVariantState(
            skipped: {_dotprod},
            crashes: {_i8mm: (count: 1, pid: 3)},
          ).toJson(),
        ),
      );
      final written = DateTime(2020);
      stateFile().setLastModifiedSync(written);
      expect(guard().candidates(_all), _all);
      expect(stateFile().lastModifiedSync(), written);
    });

    test('does nothing where it cannot write', () {
      final file = File(p.join(root.path, 'file'))..writeAsStringSync('x');
      final broken = guard(directory: p.join(file.path, 'guard'))
        ..arm(_i8mm, role: 'open')
        ..disarm(role: 'open', library: _i8mm, verifiedVersion: 'v1');
      expect(broken.candidates(_all), _all);
      expect(broken.read().verified, isEmpty);
      expect(broken.needsCheck(_i8mm), isTrue);
    });

    test('uses the process id by default', () {
      const current = CpuVariantGuard(directory: '/nowhere', variants: {_i8mm});
      expect(current.name, 'whisper');
      expect(current.processId, isNull);
      expect(CpuVariantGuard.crashLimit, 2);
    });
  });
}
