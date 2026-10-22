import 'package:bloc_test/bloc_test.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:mozhi/backup/cubit/backup_create_cubit.dart';
import 'package:mozhi/backup/data/backup_registry.dart';
import 'package:mozhi/backup/data/backup_status_store.dart';
import 'package:mozhi/core/key_value_store.dart';

import '../helpers/backup_fakes.dart';

/// A store whose writes fail.
class _ReadOnlyStore extends MemoryStore {
  @override
  Future<void> write(String key, String value) =>
      Future.error(StateError('read only'));
}

void main() {
  final now = DateTime(2026, 10, 22, 15, 4);
  late BackupRegistry registry;
  late MemorySection history;
  late MemorySection settings;
  late FakeBackupFiles files;
  late MemoryStore prefs;

  setUp(() {
    history = MemorySection('history', data: [1, 2]);
    settings = MemorySection('settings', data: {'theme': 'dark'});
    registry =
        BackupRegistry(appVersion: () async => '1.0.0+1', clock: () => now)
          ..register(history)
          ..register(settings);
    files = FakeBackupFiles();
    prefs = MemoryStore();
  });

  BackupCreateCubit build({KeyValueStore? store}) => BackupCreateCubit(
    registry: registry,
    files: files,
    status: BackupStatusStore(store ?? prefs),
    codec: testCodec,
    clock: () => now,
  );

  test('starts with every section selected and secrets off', () {
    final state = build().state;

    expect(state.sections, ['history', 'settings']);
    expect(state.selected, {'history', 'settings'});
    expect(state.includeSecrets, isFalse);
    expect(state.status, BackupCreateStatus.editing);
    expect(state.canCreate, isTrue);
  });

  test('fileNameFor uses the date', () {
    expect(
      BackupCreateCubit.fileNameFor(DateTime(2026, 3, 4, 23, 59)),
      'mozhi-2026-03-04.mozhibackup',
    );
  });

  blocTest<BackupCreateCubit, BackupCreateState>(
    'load reads the last backup date',
    setUp: () => prefs.values[BackupStatusStore.lastBackupKey] =
        '2026-10-01T08:00:00.000Z',
    build: build,
    act: (cubit) => cubit.load(),
    expect: () => [
      isA<BackupCreateState>().having(
        (s) => s.lastBackupAt,
        'lastBackupAt',
        DateTime.utc(2026, 10, 1, 8).toLocal(),
      ),
    ],
  );

  blocTest<BackupCreateCubit, BackupCreateState>(
    'load reports a failing store',
    build: () => build(store: _BrokenReadStore()),
    act: (cubit) => cubit.load(),
    expect: () => <BackupCreateState>[],
    errors: () => [isStateError],
  );

  blocTest<BackupCreateCubit, BackupCreateState>(
    'toggles sections (unknown ids are ignored) and secrets',
    build: build,
    act: (cubit) => cubit
      ..toggleSection('settings', selected: false)
      ..toggleSection('unknown', selected: true)
      ..setIncludeSecrets(include: true)
      ..toggleSection('settings', selected: true),
    expect: () => [
      isA<BackupCreateState>().having((s) => s.selected, 'selected', {
        'history',
      }),
      isA<BackupCreateState>().having(
        (s) => s.includeSecrets,
        'includeSecrets',
        isTrue,
      ),
      isA<BackupCreateState>().having((s) => s.selected, 'selected', {
        'history',
        'settings',
      }),
    ],
  );

  test('nothing selected: no backup', () async {
    final cubit = build()
      ..toggleSection('history', selected: false)
      ..toggleSection('settings', selected: false);

    expect(cubit.state.canCreate, isFalse);
    await cubit.create('correct horse battery staple');
    expect(files.saved, isEmpty);
  });

  test('creates, saves and records the backup', () async {
    final cubit = build()..toggleSection('settings', selected: false);

    await cubit.create('correct horse battery staple');

    expect(cubit.state.status, BackupCreateStatus.saved);
    expect(cubit.state.fileName, 'mozhi-2026-10-22.mozhibackup');
    expect(cubit.state.lastBackupAt, now);
    expect(history.exports, [false]);
    expect(settings.exports, isEmpty);
    final bytes = files.saved['mozhi-2026-10-22.mozhibackup']!;
    final snapshot = await testCodec.decrypt(
      bytes,
      'correct horse battery staple',
    );
    expect(snapshot.sections.keys, ['history']);
    expect(snapshot.appVersion, '1.0.0+1');
    expect(await BackupStatusStore(prefs).lastBackupAt(), now);
  });

  test('passes includeSecrets on', () async {
    final cubit = build()..setIncludeSecrets(include: true);

    await cubit.create('correct horse battery staple');

    expect(history.exports, [true]);
  });

  blocTest<BackupCreateCubit, BackupCreateState>(
    'a cancelled save goes back to editing and records nothing',
    setUp: () => files.accept = false,
    build: build,
    act: (cubit) => cubit.create('correct horse battery staple'),
    expect: () => [
      isA<BackupCreateState>().having(
        (s) => s.status,
        'status',
        BackupCreateStatus.working,
      ),
      isA<BackupCreateState>().having(
        (s) => s.status,
        'status',
        BackupCreateStatus.editing,
      ),
    ],
    verify: (_) => expect(prefs.values, isEmpty),
  );

  blocTest<BackupCreateCubit, BackupCreateState>(
    'names the section that could not be read',
    setUp: () => settings.failExport = true,
    build: build,
    act: (cubit) => cubit.create('correct horse battery staple'),
    expect: () => [
      isA<BackupCreateState>(),
      isA<BackupCreateState>()
          .having((s) => s.status, 'status', BackupCreateStatus.failure)
          .having((s) => s.failure, 'failure', BackupCreateFailure.section)
          .having((s) => s.failedSection, 'failedSection', 'settings'),
    ],
    errors: () => [isA<BackupSectionException>()],
  );

  blocTest<BackupCreateCubit, BackupCreateState>(
    'a failing save is reported, and edit goes back',
    setUp: () => files.saveError = StateError('disk full'),
    build: build,
    act: (cubit) async {
      await cubit.create('correct horse battery staple');
      cubit.edit();
    },
    expect: () => [
      isA<BackupCreateState>(),
      isA<BackupCreateState>().having(
        (s) => s.failure,
        'failure',
        BackupCreateFailure.save,
      ),
      isA<BackupCreateState>()
          .having((s) => s.status, 'status', BackupCreateStatus.editing)
          .having((s) => s.failure, 'failure', isNull),
    ],
    errors: () => [isStateError],
  );

  test('a date that cannot be recorded still saves the backup', () async {
    final cubit = build(store: _ReadOnlyStore());
    final errors = <Object>[];
    final subscription = cubit.stream.listen((_) {}, onError: errors.add);

    await cubit.create('correct horse battery staple');

    expect(cubit.state.status, BackupCreateStatus.saved);
    expect(files.saved, hasLength(1));
    await subscription.cancel();
  });

  test('never keeps the passphrase', () async {
    final cubit = build();

    await cubit.create('correct horse battery staple');

    expect(cubit.state.toString(), isNot(contains('horse')));
    expect(cubit.state.props.join(), isNot(contains('horse')));
  });

  test('stops quietly when closed while working', () async {
    final cubit = build();
    final future = cubit.create('correct horse battery staple');
    await cubit.close();

    await future;
    expect(files.saved, isEmpty);
  });
}

/// A store whose reads fail.
class _BrokenReadStore extends MemoryStore {
  @override
  Future<String?> read(String key) => Future.error(StateError('broken'));
}
