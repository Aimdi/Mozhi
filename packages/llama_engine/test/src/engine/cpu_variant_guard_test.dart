import 'dart:convert';
import 'dart:io';

import 'package:flutter_test/flutter_test.dart';
import 'package:llama_engine/src/engine/cpu_variant_guard.dart';
import 'package:path/path.dart' as p;

const _i8mm = 'libmozhi_llama_i8mm.so';
const _dotprod = 'libmozhi_llama_dotprod.so';
const _baseline = 'libmozhi_llama.so';
const List<String> _all = [_i8mm, _baseline];

void main() {
  late Directory root;

  setUp(() => root = Directory.systemTemp.createTempSync('llama_guard_'));
  tearDown(() => root.deleteSync(recursive: true));

  CpuVariantGuard guard({int processId = 100, String? directory}) =>
      CpuVariantGuard(
        directory: directory ?? root.path,
        variants: const {_i8mm, _dotprod},
        processId: processId,
      );

  File marker(String role) =>
      File(p.join(root.path, 'llama_cpu_variant.$role.marker'));

  group(CpuVariantState, () {
    test('round-trips through JSON', () {
      const state = CpuVariantState(
        skipped: {_i8mm},
        verified: {_dotprod: 'v1'},
      );
      final read = CpuVariantState.fromJson(
        jsonDecode(jsonEncode(state.toJson())),
      );
      expect(read.skipped, {_i8mm});
      expect(read.verified, {_dotprod: 'v1'});
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
      });
      expect(partly.skipped, {_i8mm});
      expect(partly.verified, {_i8mm: 'v'});
    });
  });

  group(CpuVariantGuard, () {
    test('keeps every candidate while nothing crashed', () {
      expect(guard().candidates(_all), _all);
      expect(guard().read().skipped, isEmpty);
    });

    test('a marker of another process skips its variant for good', () {
      guard(processId: 1).arm(_i8mm, role: 'open');
      expect(marker('open').existsSync(), isTrue);

      // The next start (another process) finds it.
      final next = guard(processId: 2);
      expect(next.candidates(_all), [_baseline]);
      expect(marker('open').existsSync(), isFalse);
      expect(next.read().skipped, {_i8mm});
      // Remembered without the marker.
      expect(guard(processId: 3).candidates(_all), [_baseline]);
    });

    test('a marker of this process is a step that runs now', () {
      final current = guard(processId: 7)..arm(_i8mm, role: 'compute');
      expect(current.candidates(_all), _all);
      expect(marker('compute').existsSync(), isTrue);
      current.disarm(role: 'compute');
      expect(marker('compute').existsSync(), isFalse);
    });

    test('a crash of a verified variant drops its verification', () {
      guard(processId: 1)
        ..arm(_i8mm, role: 'compute')
        ..disarm(role: 'compute', library: _i8mm, verifiedVersion: 'v1');
      expect(guard().read().verified, {_i8mm: 'v1'});
      expect(guard().needsCheck(_i8mm, version: 'v1'), isFalse);

      guard(processId: 1).arm(_i8mm, role: 'open');
      expect(guard(processId: 2).candidates(_all), [_baseline]);
      expect(guard().read().verified, isEmpty);
    });

    test('guards only its variants', () {
      final current = guard()..arm(_baseline, role: 'open');
      expect(marker('open').existsSync(), isFalse);
      expect(current.needsCheck(_baseline), isFalse);
      expect(current.needsCheck('/custom/libmozhi_llama.so'), isFalse);
      current.disarm(role: 'open', library: _baseline, verifiedVersion: 'v1');
      expect(current.read().verified, isEmpty);

      // A marker naming something else is dropped without skipping it.
      marker('open')
          .writeAsStringSync(jsonEncode({'library': _baseline, 'pid': 1}));
      expect(current.candidates(_all), _all);
      expect(marker('open').existsSync(), isFalse);
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

    test('drops damaged markers and state', () {
      marker('open').writeAsStringSync('{');
      File(p.join(root.path, 'llama_cpu_variant.x.marker'))
          .writeAsStringSync(jsonEncode({'library': 3}));
      File(p.join(root.path, 'llama_cpu_variants.json')).writeAsStringSync('[');
      File(p.join(root.path, 'unrelated.marker')).writeAsStringSync('x');
      expect(guard().candidates(_all), _all);
      expect(marker('open').existsSync(), isFalse);
      expect(File(p.join(root.path, 'unrelated.marker')).existsSync(), isTrue);
      expect(guard().read().skipped, isEmpty);
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
      expect(current.name, 'llama');
      expect(current.processId, isNull);
    });
  });
}
