import 'dart:io';

import 'package:bloc_test/bloc_test.dart';
import 'package:flutter/foundation.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:mocktail/mocktail.dart';
import 'package:mozhi/platform/free_space.dart';
import 'package:mozhi/platform/model_file_picker.dart';
import 'package:mozhi/platform/native_memory.dart';
import 'package:mozhi/voice/voice.dart';
import 'package:whisper_speech/whisper_speech.dart';

class _MockSpeechInput extends Mock implements SpeechInputService;

class _MockOfflineSpeech extends Mock implements OfflineSpeech;

class _MockPicker extends Mock implements ModelFilePicker;

final _tiny = WhisperCatalogModel(
  id: 'tiny',
  name: 'ggml-tiny.bin',
  url: Uri.parse('https://models.example/ggml-tiny.bin'),
  size: 100,
  sha1: 'a' * 40,
);
final _base = WhisperCatalogModel(
  id: 'base',
  name: 'ggml-base.bin',
  url: Uri.parse('https://models.example/ggml-base.bin'),
  size: 200,
  sha1: 'b' * 40,
);
final _tinyModel = VoiceModel(id: 'tiny', sizeBytes: 100, url: _tiny.url);
final _baseModel = VoiceModel(id: 'base', sizeBytes: 200, url: _base.url);

void main() {
  late _MockSpeechInput speechInput;
  late _MockOfflineSpeech offline;
  late _MockPicker picker;
  late ValueNotifier<VoiceInputEngine> engine;
  late Set<String> installed;

  final ready = VoiceSettingsState(
    status: VoiceSettingsStatus.ready,
    offlineSupported: true,
    models: [_tinyModel, _baseModel],
  );

  setUp(() {
    speechInput = _MockSpeechInput();
    offline = _MockOfflineSpeech();
    picker = _MockPicker();
    engine = ValueNotifier(VoiceInputEngine.system);
    installed = {};
    when(() => speechInput.loadSettings()).thenAnswer((_) async {});
    when(() => speechInput.isOfflineSupported).thenReturn(true);
    when(() => speechInput.engine).thenReturn(engine);
    when(() => speechInput.setEngine(any())).thenAnswer((invocation) async {
      engine.value = invocation.positionalArguments.single as VoiceInputEngine;
    });
    when(() => speechInput.offlineModelsChanged()).thenAnswer((_) async {});
    when(() => offline.isAvailable).thenReturn(true);
    when(() => offline.models).thenReturn([_tiny, _base]);
    when(() => offline.installed()).thenAnswer((_) async => {...installed});
    when(() => offline.selected())
        .thenAnswer((_) async => installed.isEmpty ? null : installed.last);
    when(
      () => offline.download(
        any(),
        overMeteredNetwork: any(named: 'overMeteredNetwork'),
        onProgress: any(named: 'onProgress'),
      ),
    ).thenAnswer((invocation) async {
      final progress =
          invocation.namedArguments[#onProgress] as void Function(double)?;
      progress?.call(0.004);
      progress?.call(0.005);
      progress?.call(0.5);
      installed.add(invocation.positionalArguments.single as String);
    });
    when(() => offline.delete(any())).thenAnswer((invocation) async {
      installed.remove(invocation.positionalArguments.single);
    });
    when(() => offline.select(any())).thenAnswer((_) async {});
    when(() => picker.clearCopies()).thenAnswer((_) async {});
  });

  setUpAll(() {
    registerFallbackValue(VoiceInputEngine.system);
    registerFallbackValue(<WhisperImportSource>[]);
  });

  VoiceSettingsCubit build({bool withOffline = true}) => VoiceSettingsCubit(
    speechInput: speechInput,
    offline: withOffline ? offline : null,
    picker: picker,
  );

  group('load', () {
    blocTest<VoiceSettingsCubit, VoiceSettingsState>(
      'lists the models, the installed ones and the engine',
      setUp: () {
        installed = {'tiny'};
        engine.value = VoiceInputEngine.whisper;
      },
      build: build,
      act: (cubit) => cubit.load(),
      expect: () => [
        const VoiceSettingsState(status: VoiceSettingsStatus.loading),
        ready.copyWith(
          engine: VoiceInputEngine.whisper,
          installed: {'tiny'},
          selected: () => 'tiny',
        ),
      ],
    );

    blocTest<VoiceSettingsCubit, VoiceSettingsState>(
      'offers no models without Whisper',
      build: () => build(withOffline: false),
      act: (cubit) => cubit.load(),
      skip: 1,
      expect: () => [
        const VoiceSettingsState(status: VoiceSettingsStatus.ready),
      ],
    );

    blocTest<VoiceSettingsCubit, VoiceSettingsState>(
      'offers no models where Whisper cannot run',
      setUp: () => when(() => offline.isAvailable).thenReturn(false),
      build: build,
      act: (cubit) => cubit.load(),
      skip: 1,
      expect: () => [
        const VoiceSettingsState(status: VoiceSettingsStatus.ready),
      ],
    );

    blocTest<VoiceSettingsCubit, VoiceSettingsState>(
      'reports a failing model listing',
      setUp: () =>
          when(() => offline.installed())
              .thenThrow(const FileSystemException('x')),
      build: build,
      act: (cubit) => cubit.load(),
      skip: 1,
      expect: () => [ready],
      errors: () => [isA<FileSystemException>()],
    );
  });

  group('memory', () {
    // Needs 3000 MiB of RAM (tool/whisper_catalog.py's small).
    final small = WhisperCatalogModel(
      id: 'small-q5_1',
      name: 'ggml-small-q5_1.bin',
      url: Uri.parse('https://models.example/ggml-small-q5_1.bin'),
      size: 300,
      sha1: 'c' * 40,
      minRamMb: 3000,
    );
    final smallModel = VoiceModel(
      id: 'small-q5_1',
      sizeBytes: 300,
      url: small.url,
    );
    const mib = 1024 * 1024;

    setUp(() {
      when(() => offline.models).thenReturn([_tiny, _base, small]);
      // A "3 GB" phone.
      when(() => offline.memory)
          .thenReturn(const DeviceMemory(totalBytes: 2765 * mib));
    });

    blocTest<VoiceSettingsCubit, VoiceSettingsState>(
      'does not list a model the device has too little memory for',
      build: build,
      act: (cubit) => cubit.load(),
      skip: 1,
      expect: () => [ready],
    );

    blocTest<VoiceSettingsCubit, VoiceSettingsState>(
      'lists it with enough memory',
      setUp: () =>
          when(() => offline.memory)
              .thenReturn(const DeviceMemory(totalBytes: 3686 * mib)),
      build: build,
      act: (cubit) => cubit.load(),
      skip: 1,
      expect: () => [
        ready.copyWith(models: [_tinyModel, _baseModel, smallModel]),
      ],
    );

    blocTest<VoiceSettingsCubit, VoiceSettingsState>(
      'lists it while it is installed (imported), until it is deleted',
      setUp: () => installed = {'small-q5_1'},
      build: build,
      act: (cubit) async {
        await cubit.load();
        expect(cubit.state.models, [_tinyModel, _baseModel, smallModel]);
        expect(cubit.state.selected, 'small-q5_1');
        await cubit.delete('small-q5_1');
      },
      verify: (cubit) {
        expect(cubit.state.models, [_tinyModel, _baseModel]);
        expect(cubit.state.installed, isEmpty);
        expect(cubit.state.outcome?.succeeded, isTrue);
      },
    );
  });

  blocTest<VoiceSettingsCubit, VoiceSettingsState>(
    'setEngine saves the choice',
    build: build,
    act: (cubit) => cubit.setEngine(VoiceInputEngine.whisper),
    expect: () => [const VoiceSettingsState(engine: VoiceInputEngine.whisper)],
    verify: (_) =>
        verify(() => speechInput.setEngine(VoiceInputEngine.whisper)).called(1),
  );

  blocTest<VoiceSettingsCubit, VoiceSettingsState>(
    'setEngine keeps the choice when it cannot be saved',
    setUp: () =>
        when(() => speechInput.setEngine(any())).thenThrow(StateError('store')),
    build: build,
    act: (cubit) => cubit.setEngine(VoiceInputEngine.whisper),
    expect: () => [const VoiceSettingsState(engine: VoiceInputEngine.whisper)],
    errors: () => [isStateError],
  );

  group('download', () {
    blocTest<VoiceSettingsCubit, VoiceSettingsState>(
      'reports progress in whole percent and the outcome',
      build: build,
      seed: () => ready,
      act: (cubit) => cubit.download('tiny'),
      expect: () => [
        ready.copyWith(pending: {'tiny': VoiceModelOperation.download}),
        ready.copyWith(
          pending: {'tiny': VoiceModelOperation.download},
          progress: {'tiny': 0.004},
        ),
        ready.copyWith(
          pending: {'tiny': VoiceModelOperation.download},
          progress: {'tiny': 0.5},
        ),
        ready.copyWith(
          pending: {'tiny': VoiceModelOperation.download},
          progress: {'tiny': 0.5},
          installed: {'tiny'},
          selected: () => 'tiny',
        ),
        ready.copyWith(
          installed: {'tiny'},
          selected: () => 'tiny',
          outcome: () => const VoiceModelOutcome(
            model: 'tiny',
            operation: VoiceModelOperation.download,
            succeeded: true,
          ),
        ),
      ],
      verify: (_) {
        verify(() => speechInput.offlineModelsChanged()).called(1);
        verify(
          () => offline.download('tiny', onProgress: any(named: 'onProgress')),
        ).called(1);
      },
    );

    blocTest<VoiceSettingsCubit, VoiceSettingsState>(
      'asks before a metered download and can download anyway',
      setUp: () {
        when(
          () => offline.download(any(), onProgress: any(named: 'onProgress')),
        ).thenThrow(const VoiceModelMeteredException());
      },
      build: build,
      seed: () => ready,
      act: (cubit) async {
        await cubit.download('base');
        expect(cubit.state.outcome!.needsMeteredConsent, isTrue);
        await cubit.download('base', overMeteredNetwork: true);
      },
      verify: (cubit) {
        expect(cubit.state.outcome!.succeeded, isTrue);
        expect(cubit.state.installed, {'base'});
        verify(
          () => offline.download(
            'base',
            overMeteredNetwork: true,
            onProgress: any(named: 'onProgress'),
          ),
        ).called(1);
      },
      // Metered networks are not errors.
      errors: () => <Object>[],
    );

    final failures = <String, (Object, VoiceModelError)>{
      'checksum': (
        const WhisperChecksumException('tiny', 'bad'),
        const VoiceModelError(VoiceModelErrorKind.checksum),
      ),
      'server': (
        const WhisperDownloadException('tiny', 'HTTP 503', statusCode: 503),
        const VoiceModelError(VoiceModelErrorKind.server, statusCode: 503),
      ),
      'network': (
        const WhisperDownloadException('tiny', 'reset'),
        const VoiceModelError(VoiceModelErrorKind.network),
      ),
      'storage': (
        const FileSystemException('full'),
        const VoiceModelError(VoiceModelErrorKind.storage),
      ),
      'unknown': (
        StateError('?'),
        const VoiceModelError(VoiceModelErrorKind.unknown),
      ),
    };
    for (final MapEntry(key: name, value: (error, expected))
        in failures.entries) {
      blocTest<VoiceSettingsCubit, VoiceSettingsState>(
        'classifies a $name failure',
        setUp: () => when(
          () => offline.download(any(), onProgress: any(named: 'onProgress')),
        ).thenThrow(error),
        build: build,
        seed: () => ready,
        act: (cubit) => cubit.download('tiny'),
        verify: (cubit) => expect(
          cubit.state.outcome,
          VoiceModelOutcome(
            model: 'tiny',
            operation: VoiceModelOperation.download,
            succeeded: false,
            error: expected,
          ),
        ),
        errors: () => [error],
      );
    }

    blocTest<VoiceSettingsCubit, VoiceSettingsState>(
      'ignores unknown models, running operations and no Whisper',
      build: build,
      seed: () =>
          ready.copyWith(pending: {'tiny': VoiceModelOperation.download}),
      act: (cubit) async {
        await cubit.download('tiny');
        await cubit.download('large');
      },
      expect: () => <VoiceSettingsState>[],
    );

    blocTest<VoiceSettingsCubit, VoiceSettingsState>(
      'does nothing without Whisper',
      build: () => build(withOffline: false),
      seed: () => ready,
      act: (cubit) async {
        await cubit.download('tiny');
        await cubit.delete('tiny');
        await cubit.select('tiny');
        await cubit.importFromFiles();
      },
      expect: () => <VoiceSettingsState>[],
    );
  });

  group('delete and select', () {
    blocTest<VoiceSettingsCubit, VoiceSettingsState>(
      'delete removes a model',
      setUp: () => installed = {'tiny', 'base'},
      build: build,
      seed: () =>
          ready.copyWith(installed: {'tiny', 'base'}, selected: () => 'base'),
      act: (cubit) => cubit.delete('base'),
      verify: (cubit) {
        expect(cubit.state.installed, {'tiny'});
        expect(cubit.state.selected, 'tiny');
        expect(
          cubit.state.outcome,
          const VoiceModelOutcome(
            model: 'base',
            operation: VoiceModelOperation.delete,
            succeeded: true,
          ),
        );
        verify(() => speechInput.offlineModelsChanged()).called(1);
      },
    );

    blocTest<VoiceSettingsCubit, VoiceSettingsState>(
      'select switches the model in use',
      setUp: () {
        installed = {'tiny', 'base'};
        when(() => offline.selected()).thenAnswer((_) async => 'tiny');
      },
      build: build,
      seed: () =>
          ready.copyWith(installed: {'tiny', 'base'}, selected: () => 'base'),
      act: (cubit) async {
        await cubit.select('tiny');
        // The model in use, or one that is not installed: nothing.
        await cubit.select('tiny');
        await cubit.select('large');
      },
      expect: () => [
        ready.copyWith(installed: {'tiny', 'base'}, selected: () => 'tiny'),
      ],
      verify: (_) => verify(() => offline.select('tiny')).called(1),
    );

    blocTest<VoiceSettingsCubit, VoiceSettingsState>(
      'select reports a failing store',
      setUp: () {
        installed = {'tiny', 'base'};
        when(() => offline.select(any())).thenThrow(StateError('store'));
      },
      build: build,
      seed: () =>
          ready.copyWith(installed: {'tiny', 'base'}, selected: () => 'base'),
      act: (cubit) => cubit.select('tiny'),
      errors: () => [isStateError],
    );

    blocTest<VoiceSettingsCubit, VoiceSettingsState>(
      'a failing service notification is reported',
      setUp: () =>
          when(() => speechInput.offlineModelsChanged())
              .thenThrow(StateError('closed')),
      build: build,
      seed: () => ready,
      act: (cubit) => cubit.download('tiny'),
      errors: () => [isStateError],
    );
  });

  group('importFromFiles', () {
    WhisperImportResult result({
      List<WhisperImportOutcome> models = const [],
      List<File> unmatched = const [],
    }) => WhisperImportResult(models: models, unmatched: unmatched);

    blocTest<VoiceSettingsCubit, VoiceSettingsState>(
      'installs the picked models',
      setUp: () {
        when(() => picker.pick(onCopying: any(named: 'onCopying'))).thenAnswer((
          invocation,
        ) async {
          (invocation.namedArguments[#onCopying] as void Function()?)?.call();
          return [
            PickedModelFile.local('/picked/ggml-tiny.bin'),
            PickedModelFile.local('/picked/notes.txt'),
          ];
        });
        when(() => offline.importFiles(any())).thenAnswer((_) async {
          installed.add('tiny');
          return result(
            models: [
              WhisperImportOutcome(
                model: _tiny,
                status: WhisperImportStatus.installed,
              ),
            ],
            unmatched: [File('/picked/notes.txt')],
          );
        });
      },
      build: build,
      seed: () => ready,
      act: (cubit) => cubit.importFromFiles(),
      expect: () => [
        ready.copyWith(importing: true),
        ready.copyWith(
          importing: true,
          installed: {'tiny'},
          selected: () => 'tiny',
        ),
        ready.copyWith(
          installed: {'tiny'},
          selected: () => 'tiny',
          importOutcome: () => const VoiceImportOutcome(
            models: {'tiny': WhisperImportStatus.installed},
            unmatchedFiles: 1,
          ),
        ),
      ],
      verify: (_) {
        verify(() => picker.clearCopies()).called(1);
        verify(() => speechInput.offlineModelsChanged()).called(1);
      },
    );

    blocTest<VoiceSettingsCubit, VoiceSettingsState>(
      'copies picked documents straight into the models folder',
      setUp: () {
        when(() => picker.pick(onCopying: any(named: 'onCopying'))).thenAnswer(
          (_) async => [
            PickedModelFile(
              name: 'ggml-tiny.bin',
              length: 100,
              copy: (destination, maxBytes) async => 0,
            ),
          ],
        );
        when(() => offline.importSources(any())).thenAnswer(
          (_) async => result(
            models: [
              WhisperImportOutcome(
                model: _tiny,
                status: WhisperImportStatus.failed,
                error: const WhisperInsufficientSpaceException(
                  'tiny',
                  'full',
                  requiredBytes: 300,
                  availableBytes: 100,
                ),
              ),
            ],
          ),
        );
      },
      build: build,
      seed: () => ready,
      act: (cubit) => cubit.importFromFiles(),
      verify: (cubit) {
        verify(() => offline.importSources(any())).called(1);
        verifyNever(() => offline.importFiles(any()));
        expect(
          cubit.state.importOutcome,
          const VoiceImportOutcome(
            models: {'tiny': WhisperImportStatus.failed},
            space: SpaceShortfall(requiredBytes: 300, availableBytes: 100),
          ),
        );
      },
    );

    blocTest<VoiceSettingsCubit, VoiceSettingsState>(
      'cancelling the picker changes nothing',
      setUp: () =>
          when(() => picker.pick(onCopying: any(named: 'onCopying')))
              .thenAnswer((_) async => const <PickedModelFile>[]),
      build: build,
      seed: () => ready,
      act: (cubit) => cubit.importFromFiles(),
      expect: () => <VoiceSettingsState>[],
    );

    blocTest<VoiceSettingsCubit, VoiceSettingsState>(
      'a picker that started copying and was cancelled stops importing',
      setUp: () => when(() => picker.pick(onCopying: any(named: 'onCopying')))
          .thenAnswer((invocation) async {
            (invocation.namedArguments[#onCopying] as void Function()?)?.call();
            return const <PickedModelFile>[];
          }),
      build: build,
      seed: () => ready,
      act: (cubit) => cubit.importFromFiles(),
      expect: () => [ready.copyWith(importing: true), ready],
    );

    blocTest<VoiceSettingsCubit, VoiceSettingsState>(
      'a failing import is reported',
      setUp: () {
        when(() => picker.pick(onCopying: any(named: 'onCopying')))
            .thenAnswer((_) async => [PickedModelFile.local('/picked/x.bin')]);
        when(() => offline.importFiles(any()))
            .thenThrow(const FileSystemException('unreadable'));
        when(() => picker.clearCopies()).thenThrow(StateError('cache'));
      },
      build: build,
      seed: () => ready,
      act: (cubit) => cubit.importFromFiles(),
      verify: (cubit) {
        expect(cubit.state.importing, isFalse);
        expect(
          cubit.state.importOutcome,
          const VoiceImportOutcome(failed: true),
        );
      },
      errors: () => [isStateError, isA<FileSystemException>()],
    );

    blocTest<VoiceSettingsCubit, VoiceSettingsState>(
      'does nothing while importing or without Whisper here',
      build: build,
      seed: () => ready.copyWith(importing: true),
      act: (cubit) => cubit.importFromFiles(),
      expect: () => <VoiceSettingsState>[],
      verify: (_) =>
          verifyNever(() => picker.pick(onCopying: any(named: 'onCopying'))),
    );
  });

  test('state helpers', () {
    final state = ready.copyWith(installed: {'tiny'});
    expect(state.isInstalled('tiny'), isTrue);
    expect(state.isInstalled('base'), isFalse);
    expect(state.model('base'), _baseModel);
    expect(state.model('large'), isNull);
    expect(
      const VoiceModelOutcome(
        model: 'tiny',
        operation: VoiceModelOperation.download,
        succeeded: true,
      ).needsMeteredConsent,
      isFalse,
    );
  });
}
