import 'dart:typed_data';

import 'package:bloc_test/bloc_test.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:mozhi/backup/cubit/backup_restore_cubit.dart';
import 'package:mozhi/backup/data/backup_codec.dart';
import 'package:mozhi/backup/data/backup_files.dart';
import 'package:mozhi/backup/data/backup_registry.dart';

import '../helpers/backup_fakes.dart';

void main() {
  final createdAt = DateTime.utc(2026, 10, 1, 8);
  final snapshot = BackupSnapshot(
    createdAt: createdAt,
    appVersion: '1.0.0+1',
    sections: const {
      'history': BackupSectionData(version: 1, data: [3, 4]),
      'presets': BackupSectionData(version: 1, data: ['p']),
      'newer': BackupSectionData(version: 1, data: null),
    },
  );
  late Uint8List bytes;
  late BackupRegistry registry;
  late MemorySection history;
  late MemorySection presets;
  late FakeBackupFiles files;

  setUpAll(() async {
    bytes = await testCodec.encrypt(snapshot, 'pass phrase words');
  });

  setUp(() {
    history = MemorySection('history', data: [1, 2]);
    presets = MemorySection('presets', data: const <Object?>[]);
    registry = BackupRegistry()
      ..register(history)
      ..register(presets)
      ..register(MemorySection('settings'));
    files = FakeBackupFiles()
      ..picked = PickedBackupFile(
        name: 'mozhi-2026-10-01.mozhibackup',
        bytes: bytes,
      );
  });

  BackupRestoreCubit build({BackupSnapshot? from}) => BackupRestoreCubit(
    registry: registry,
    files: files,
    codec: testCodec,
    snapshot: from,
  );

  Future<BackupRestoreCubit> unlocked() async {
    final cubit = build();
    await cubit.pickFile();
    await cubit.unlock('pass phrase words');
    return cubit;
  }

  test('starts at pick', () {
    expect(build().state, const BackupRestoreState());
  });

  test('with a snapshot starts at review with the known sections', () {
    final state = build(from: snapshot).state;

    expect(state.step, BackupRestoreStep.review);
    expect(state.snapshot, snapshot);
    expect(state.selected, {'history', 'presets'});
  });

  blocTest<BackupRestoreCubit, BackupRestoreState>(
    'pickFile reads the header',
    build: build,
    act: (cubit) => cubit.pickFile(),
    expect: () => [
      isA<BackupRestoreState>()
          .having((s) => s.step, 'step', BackupRestoreStep.locked)
          .having((s) => s.fileName, 'fileName', 'mozhi-2026-10-01.mozhibackup')
          .having((s) => s.header?.createdAt, 'createdAt', createdAt)
          .having((s) => s.header?.appVersion, 'appVersion', '1.0.0+1'),
    ],
  );

  blocTest<BackupRestoreCubit, BackupRestoreState>(
    'a cancelled pick changes nothing',
    setUp: () => files.picked = null,
    build: build,
    act: (cubit) => cubit.pickFile(),
    expect: () => <BackupRestoreState>[],
  );

  for (final (name, picked, failure) in [
    (
      'not a backup',
      PickedBackupFile(name: 'notes.txt', bytes: Uint8List.fromList([1, 2])),
      BackupRestoreFailure.notBackup,
    ),
    (
      'a newer format',
      PickedBackupFile(
        name: 'new.mozhibackup',
        bytes: Uint8List.fromList([...'MOZHIBAK'.codeUnits, 9, 0, 0]),
      ),
      BackupRestoreFailure.newerVersion,
    ),
  ]) {
    blocTest<BackupRestoreCubit, BackupRestoreState>(
      'pickFile refuses $name',
      setUp: () => files.picked = picked,
      build: build,
      act: (cubit) => cubit.pickFile(),
      expect: () => [
        isA<BackupRestoreState>()
            .having((s) => s.step, 'step', BackupRestoreStep.pick)
            .having((s) => s.failure, 'failure', failure),
      ],
    );
  }

  blocTest<BackupRestoreCubit, BackupRestoreState>(
    'pickFile reports a file too large',
    setUp: () => files.pickError = const BackupFileTooLargeException(),
    build: build,
    act: (cubit) => cubit.pickFile(),
    expect: () => [
      isA<BackupRestoreState>().having(
        (s) => s.failure,
        'failure',
        BackupRestoreFailure.tooLarge,
      ),
    ],
  );

  blocTest<BackupRestoreCubit, BackupRestoreState>(
    'pickFile reports a file it cannot read',
    setUp: () => files.pickError = StateError('no permission'),
    build: build,
    act: (cubit) => cubit.pickFile(),
    expect: () => [
      isA<BackupRestoreState>().having(
        (s) => s.failure,
        'failure',
        BackupRestoreFailure.unreadable,
      ),
    ],
    errors: () => [isStateError],
  );

  test('unlock decrypts and selects the known sections', () async {
    final cubit = await unlocked();

    expect(cubit.state.step, BackupRestoreStep.review);
    expect(cubit.state.snapshot, snapshot);
    expect(cubit.state.selected, {'history', 'presets'});
    expect(cubit.state.failure, isNull);
  });

  test('unlock before a file, or twice, does nothing', () async {
    final cubit = build();
    await cubit.unlock('pass phrase words');
    expect(cubit.state.step, BackupRestoreStep.pick);

    final open = await unlocked();
    await open.unlock('pass phrase words');
    expect(open.state.step, BackupRestoreStep.review);
  });

  test('a wrong passphrase goes back to locked, saying so', () async {
    final cubit = build();
    await cubit.pickFile();
    final steps = <BackupRestoreStep>[];
    final subscription = cubit.stream.listen((s) => steps.add(s.step));

    await cubit.unlock('wrong');
    await pumpEventQueue();

    expect(steps, [BackupRestoreStep.unlocking, BackupRestoreStep.locked]);
    expect(cubit.state.failure, BackupRestoreFailure.wrongPassphrase);
    await subscription.cancel();

    await cubit.unlock('pass phrase words');
    expect(cubit.state.step, BackupRestoreStep.review);
    expect(cubit.state.failure, isNull);
  });

  test('a backup that decrypts to a newer format says so', () async {
    final codec = _NewerCodec();
    final cubit = BackupRestoreCubit(
      registry: registry,
      files: files,
      codec: codec,
    );
    await cubit.pickFile();

    await cubit.unlock('pass phrase words');

    expect(cubit.state.step, BackupRestoreStep.locked);
    expect(cubit.state.failure, BackupRestoreFailure.newerVersion);
  });

  test('toggleSection changes the selection of known sections only', () async {
    final cubit = await unlocked()
      ..toggleSection('presets', selected: false)
      ..toggleSection('newer', selected: true)
      ..toggleSection('settings', selected: true);

    expect(cubit.state.selected, {'history'});
    cubit.toggleSection('presets', selected: true);
    expect(cubit.state.selected, {'history', 'presets'});
    // Before a snapshot: nothing.
    final locked = build()..toggleSection('history', selected: false);
    expect(locked.state.selected, isEmpty);
  });

  test('restore merges the selected sections and reports', () async {
    final cubit = await unlocked()
      ..toggleSection('presets', selected: false);

    await cubit.restore(BackupRestoreMode.merge);

    expect(cubit.state.step, BackupRestoreStep.done);
    expect(cubit.state.mode, BackupRestoreMode.merge);
    expect(
      cubit.state.report,
      const BackupRestoreReport(
        restored: ['history'],
        changes: {'history': BackupItemChange(before: 2, after: 4)},
      ),
    );
    expect(history.data, [1, 2, 3, 4]);
    expect(presets.restores, isEmpty);
  });

  test('restore replaces', () async {
    final cubit = await unlocked();

    await cubit.restore(BackupRestoreMode.replace);

    expect(history.data, [3, 4]);
    expect(presets.data, ['p']);
    expect(cubit.state.report?.restored, ['history', 'presets']);
  });

  test('restore needs a selection', () async {
    final cubit = await unlocked()
      ..toggleSection('history', selected: false)
      ..toggleSection('presets', selected: false);

    await cubit.restore(BackupRestoreMode.merge);

    expect(cubit.state.step, BackupRestoreStep.review);
    await build().restore(BackupRestoreMode.merge);
  });

  test('a failing section is named; the others are restored', () async {
    history.failRestore = true;
    final cubit = await unlocked();
    final errors = <Object>[];
    final subscription = cubit.stream.listen((_) {}, onError: errors.add);

    await cubit.restore(BackupRestoreMode.merge);

    expect(cubit.state.step, BackupRestoreStep.done);
    expect(cubit.state.failure, BackupRestoreFailure.restore);
    expect(cubit.state.failedSection, 'history');
    expect(presets.data, ['p']);
    await subscription.cancel();
  });

  test('startOver goes back to pick', () async {
    final cubit = build();
    await cubit.pickFile();

    cubit.startOver();

    expect(cubit.state, const BackupRestoreState());
    await cubit.unlock('pass phrase words');
    expect(cubit.state.step, BackupRestoreStep.pick);
  });

  test('never keeps the passphrase', () async {
    final cubit = await unlocked();

    expect(cubit.state.props.join(), isNot(contains('phrase words')));
  });

  test('closing while unlocking or restoring is quiet', () async {
    final cubit = build();
    await cubit.pickFile();
    final unlocking = cubit.unlock('pass phrase words');
    await cubit.close();
    await unlocking;

    final other = await unlocked();
    final restoring = other.restore(BackupRestoreMode.merge);
    await other.close();
    await restoring;

    history.failRestore = true;
    final failing = await unlocked();
    final failed = failing.restore(BackupRestoreMode.merge);
    await failing.close();
    await failed;
  });
}

/// Decrypts every backup to a newer snapshot format.
class _NewerCodec extends BackupCodec {
  new() : super(useIsolate: false);

  @override
  Future<BackupSnapshot> decrypt(Uint8List bytes, String passphrase) =>
      Future.error(
        const BackupFormatException(
          message: 'Newer backup format',
          newerVersion: true,
        ),
      );
}
