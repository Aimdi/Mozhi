import 'package:flutter_test/flutter_test.dart';
import 'package:mozhi/backup/data/backup_registry.dart';
import 'package:package_info_plus/package_info_plus.dart';

/// A section holding [data] in memory.
class _Section implements BackupSection {
  new(this.id, {this.version = 1, this.data, this.fail = false});

  @override
  final String id;

  @override
  final int version;

  Object? data;
  bool fail;
  final restores = <(Object?, int, BackupRestoreMode)>[];
  final exports = <bool>[];

  @override
  Future<Object?> export({required bool includeSecrets}) async {
    exports.add(includeSecrets);
    if (fail) throw StateError('export failed');
    return data;
  }

  @override
  Future<void> restore(
    Object? data, {
    required int version,
    required BackupRestoreMode mode,
  }) async {
    restores.add((data, version, mode));
    if (fail) throw StateError('restore failed');
    this.data = data;
  }
}

/// A section that counts the items of its list.
class _CountingSection extends _Section implements BackupItemCounter {
  new(super.id, {super.data});

  bool countFails = false;

  @override
  int? countItems(Object? data, {required int version}) =>
      data is List ? data.length : null;

  @override
  Future<int> countLocalItems() async {
    if (countFails) throw StateError('count failed');
    return (data as List?)?.length ?? 0;
  }
}

void main() {
  final now = DateTime.utc(2026, 10, 22, 12);
  late BackupRegistry registry;

  setUp(() {
    registry = BackupRegistry(
      appVersion: () async => '1.4.0+12',
      clock: () => now,
    );
  });

  tearDown(() => registry.dispose());

  group('register', () {
    test('keeps the order and finds sections by id', () {
      final a = _Section('a');
      final b = _Section('b');
      registry
        ..register(a)
        ..register(b);

      expect(registry.sections, [a, b]);
      expect(registry.section('b'), b);
      expect(registry.section('c'), isNull);
      expect(() => registry.sections.add(a), throwsUnsupportedError);
    });

    test('refuses a second section with the same id', () {
      registry.register(_Section('a'));

      expect(() => registry.register(_Section('a')), throwsArgumentError);
    });
  });

  group('snapshot', () {
    test('holds every section with its version', () async {
      registry
        ..register(_Section('a', data: [1, 2]))
        ..register(_Section('b', version: 3, data: {'x': true}));

      final snapshot = await registry.snapshot(includeSecrets: false);

      expect(
        snapshot,
        BackupSnapshot(
          createdAt: now,
          appVersion: '1.4.0+12',
          sections: const {
            'a': BackupSectionData(version: 1, data: [1, 2]),
            'b': BackupSectionData(version: 3, data: {'x': true}),
          },
        ),
      );
    });

    test('passes includeSecrets on and honours only', () async {
      final a = _Section('a');
      final b = _Section('b');
      registry
        ..register(a)
        ..register(b);

      final snapshot = await registry.snapshot(
        includeSecrets: true,
        only: {'b', 'unknown'},
      );

      expect(snapshot.sections.keys, ['b']);
      expect(a.exports, isEmpty);
      expect(b.exports, [true]);
    });

    test('names the section that failed', () async {
      registry
        ..register(_Section('a'))
        ..register(_Section('b', fail: true));

      await expectLater(
        registry.snapshot(includeSecrets: false),
        throwsA(
          isA<BackupSectionException>()
              .having((e) => e.sectionId, 'sectionId', 'b')
              .having((e) => e.cause, 'cause', isStateError)
              .having(
                (e) => e.toString(),
                'toString',
                isNot(contains('export')),
              ),
        ),
      );
    });

    test('writes "unknown" when the app version is not available', () async {
      final registry = BackupRegistry(
        appVersion: () async => throw StateError('no plugin'),
        clock: () => now,
      );

      final snapshot = await registry.snapshot(includeSecrets: false);

      expect(snapshot.appVersion, 'unknown');
      expect(snapshot.createdAt.isUtc, isTrue);
    });
  });

  group('restore', () {
    final snapshot = BackupSnapshot(
      createdAt: now,
      appVersion: '1',
      sections: const {
        'a': BackupSectionData(version: 1, data: [1]),
        'b': BackupSectionData(version: 2, data: 'b'),
        'newer': BackupSectionData(version: 1, data: null),
      },
    );

    test('restores each known section with its data, version and '
        'mode', () async {
      final a = _Section('a');
      final b = _Section('b', version: 2);
      final c = _Section('c', data: 'kept');
      registry
        ..register(a)
        ..register(b)
        ..register(c);

      final report = await registry.restore(
        snapshot,
        mode: BackupRestoreMode.merge,
      );

      expect(a.restores.single.$1, [1]);
      expect(a.restores.single.$2, 1);
      expect(a.restores.single.$3, BackupRestoreMode.merge);
      expect(b.restores, [('b', 2, BackupRestoreMode.merge)]);
      expect(c.restores, isEmpty);
      expect(c.data, 'kept');
      expect(
        report,
        const BackupRestoreReport(restored: ['a', 'b'], skipped: ['newer']),
      );
    });

    test('honours only', () async {
      final a = _Section('a');
      final b = _Section('b');
      registry
        ..register(a)
        ..register(b);

      final report = await registry.restore(
        snapshot,
        mode: BackupRestoreMode.replace,
        only: {'b'},
      );

      expect(a.restores, isEmpty);
      expect(report.restored, ['b']);
      expect(report.skipped, isEmpty);
    });

    test('reports item counts before and after', () async {
      final a = _CountingSection('a', data: [1, 2, 3]);
      registry.register(a);

      final report = await registry.restore(
        snapshot,
        mode: BackupRestoreMode.replace,
      );

      expect(report.changes, {
        'a': const BackupItemChange(before: 3, after: 1),
      });
    });

    test('a failing count leaves the count out, not the restore', () async {
      final a = _CountingSection('a', data: [1, 2])..countFails = true;
      registry.register(a);

      final report = await registry.restore(
        snapshot,
        mode: BackupRestoreMode.replace,
      );

      expect(report.restored, ['a']);
      expect(report.changes, isEmpty);
      expect(a.data, [1]);
    });

    test('attempts every section, then rethrows the first failure', () async {
      final a = _Section('a', fail: true);
      final b = _Section('b', version: 2);
      registry
        ..register(a)
        ..register(b);
      final restored = registry.restored.first;

      await expectLater(
        registry.restore(snapshot, mode: BackupRestoreMode.merge),
        throwsA(
          isA<BackupSectionException>().having(
            (e) => e.sectionId,
            'sectionId',
            'a',
          ),
        ),
      );
      expect(b.restores, hasLength(1));
      expect(await restored, {'a', 'b'});
    });

    test('tells listeners which sections it restored', () async {
      registry
        ..register(_Section('a'))
        ..register(_Section('c'));
      final events = <Set<String>>[];
      final subscription = registry.restored.listen(events.add);

      await registry.restore(snapshot, mode: BackupRestoreMode.merge);
      await registry.restore(
        snapshot,
        mode: BackupRestoreMode.merge,
        only: {'c'},
      );
      await pumpEventQueue();

      expect(events, [
        {'a'},
      ]);
      await subscription.cancel();
    });
  });

  test('snapshot and restore run one at a time', () async {
    final order = <String>[];
    final section = _OrderedSection(order);
    registry.register(section);
    final snapshot = BackupSnapshot(
      createdAt: now,
      appVersion: '1',
      sections: const {'o': BackupSectionData(version: 1, data: null)},
    );

    await Future.wait([
      registry.restore(snapshot, mode: BackupRestoreMode.merge),
      registry.snapshot(includeSecrets: false),
      registry.restore(snapshot, mode: BackupRestoreMode.replace),
    ]);

    expect(order, [
      'restore start',
      'restore end',
      'export start',
      'export end',
      'restore start',
      'restore end',
    ]);
  });

  group('platformAppVersion', () {
    test('is the version and build number', () async {
      PackageInfo.setMockInitialValues(
        appName: 'Mozhi',
        packageName: 'app.mozhi',
        version: '1.4.0',
        buildNumber: '12',
        buildSignature: '',
      );

      expect(await BackupRegistry.platformAppVersion(), '1.4.0+12');
    });

    test('is the version alone without a build number', () async {
      PackageInfo.setMockInitialValues(
        appName: 'Mozhi',
        packageName: 'app.mozhi',
        version: '1.4.0',
        buildNumber: '',
        buildSignature: '',
      );

      expect(await BackupRegistry.platformAppVersion(), '1.4.0');
    });
  });
}

class _OrderedSection implements BackupSection {
  new(this.order);

  final List<String> order;

  @override
  String get id => 'o';

  @override
  int get version => 1;

  @override
  Future<Object?> export({required bool includeSecrets}) async {
    order.add('export start');
    await Future<void>.delayed(const Duration(milliseconds: 5));
    order.add('export end');
    return null;
  }

  @override
  Future<void> restore(
    Object? data, {
    required int version,
    required BackupRestoreMode mode,
  }) async {
    order.add('restore start');
    await Future<void>.delayed(const Duration(milliseconds: 5));
    order.add('restore end');
  }
}
