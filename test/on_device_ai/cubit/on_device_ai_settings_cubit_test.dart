import 'dart:async';
import 'dart:io';

import 'package:bloc_test/bloc_test.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:llama_engine/llama_engine.dart';
import 'package:mocktail/mocktail.dart';
import 'package:mozhi/offline/data/offline_model_file_picker.dart';
import 'package:mozhi/on_device_ai/cubit/on_device_ai_settings_cubit.dart';
import 'package:mozhi/on_device_ai/data/on_device_models.dart';

import '../helpers.dart';

class _MockModels extends Mock implements OnDeviceModels;

class _MockPicker extends Mock implements OfflineModelFilePicker;

void main() {
  final hy = fakeOnDeviceModel(
    'hy',
    ggufBytes(30),
    role: LlamaModelRole.translation,
    displayName: 'Hy-MT2',
  );
  final qwen = fakeOnDeviceModel('qwen', ggufBytes(20, seed: 2));
  final catalog = LlamaModelCatalog(models: [hy, qwen]);

  late _MockModels models;
  late _MockPicker picker;
  late StreamController<void> changes;
  late List<OnDeviceModel> listed;
  late Map<String, double> downloads;

  OnDeviceModel entry(
    LlamaCatalogModel model, {
    bool installed = false,
    OnDeviceFit fit = OnDeviceFit.ok,
    int partialBytes = 0,
  }) => OnDeviceModel(
    model: model,
    fit: fit,
    installed: installed,
    partialBytes: partialBytes,
  );

  setUpAll(() {
    registerFallbackValue(<String>[]);
  });

  setUp(() {
    models = _MockModels();
    picker = _MockPicker();
    changes = StreamController<void>.broadcast();
    listed = [entry(hy), entry(qwen)];
    downloads = {};
    when(() => models.ready).thenAnswer((_) async {});
    when(() => models.changes).thenAnswer((_) => changes.stream);
    when(() => models.models()).thenAnswer((_) async => listed);
    when(() => models.catalog).thenReturn(catalog);
    when(() => models.translationModel).thenReturn(null);
    when(() => models.assistantModel).thenReturn(null);
    when(() => models.downloads).thenAnswer((_) => downloads);
    when(() => models.fitOf(any())).thenReturn(OnDeviceFit.ok);
    when(() => picker.clearCopies()).thenAnswer((_) async {});
  });

  setUpAll(() => registerFallbackValue(hy));

  tearDown(() => changes.close());

  OnDeviceAiSettingsCubit build({bool move = false}) => OnDeviceAiSettingsCubit(
    models: models,
    picker: picker,
    movePickedFiles: move,
  );

  group('load', () {
    blocTest<OnDeviceAiSettingsCubit, OnDeviceAiSettingsState>(
      'without on-device AI is ready and unsupported',
      build: () => OnDeviceAiSettingsCubit(picker: picker),
      act: (cubit) => cubit.load(),
      expect: () => [
        const OnDeviceAiSettingsState(status: OnDeviceAiSettingsStatus.ready),
      ],
    );

    blocTest<OnDeviceAiSettingsCubit, OnDeviceAiSettingsState>(
      'lists the models and the ones in use',
      setUp: () {
        listed = [entry(hy, installed: true), entry(qwen)];
        when(() => models.translationModel).thenReturn('hy');
      },
      build: build,
      act: (cubit) => cubit.load(),
      expect: () => [
        const OnDeviceAiSettingsState(status: OnDeviceAiSettingsStatus.loading),
        OnDeviceAiSettingsState(
          status: OnDeviceAiSettingsStatus.loading,
          models: listed,
          translationModel: 'hy',
        ),
        OnDeviceAiSettingsState(
          status: OnDeviceAiSettingsStatus.ready,
          supported: true,
          models: listed,
          translationModel: 'hy',
        ),
      ],
      verify: (cubit) {
        expect(cubit.state.inUse('hy'), isTrue);
        expect(cubit.state.inUse('qwen'), isFalse);
        expect(cubit.state.model('qwen')!.model, qwen);
        expect(cubit.state.model('x'), isNull);
        expect(cubit.state.ofRole(LlamaModelRole.assistant).single.id, 'qwen');
      },
    );

    blocTest<OnDeviceAiSettingsCubit, OnDeviceAiSettingsState>(
      'reports a failed read and keeps what it had',
      setUp: () {
        when(() => models.ready).thenAnswer((_) async => throw StateError('x'));
        when(() => models.models()).thenThrow(StateError('folder'));
      },
      build: build,
      act: (cubit) => cubit.load(),
      errors: () => [isStateError, isStateError],
      verify: (cubit) {
        expect(cubit.state.status, OnDeviceAiSettingsStatus.ready);
        expect(cubit.state.models, isEmpty);
      },
    );

    test('follows changes made elsewhere', () async {
      final cubit = build();
      await cubit.load();
      listed = [entry(hy, installed: true), entry(qwen)];
      when(() => models.translationModel).thenReturn('hy');
      changes.add(null);
      await Future<void>.delayed(Duration.zero);
      await Future<void>.delayed(Duration.zero);
      expect(cubit.state.translationModel, 'hy');
      expect(cubit.state.models.first.installed, isTrue);
      await cubit.close();
    });

    test('shows and joins a download that runs already', () async {
      downloads = {'qwen': 0.25};
      final done = Completer<void>();
      when(() => models.download('qwen', onProgress: any(named: 'onProgress')))
          .thenAnswer((_) => done.future);
      final cubit = build();
      await cubit.load();
      expect(cubit.state.pending, {'qwen': OnDeviceModelOperation.download});
      expect(cubit.state.progress, {'qwen': 0.25});
      done.complete();
      await Future<void>.delayed(Duration.zero);
      await Future<void>.delayed(Duration.zero);
      expect(cubit.state.pending, isEmpty);
      expect(cubit.state.outcome!.succeeded, isTrue);
      await cubit.close();
    });
  });

  group('download', () {
    blocTest<OnDeviceAiSettingsCubit, OnDeviceAiSettingsState>(
      'reports progress in whole percent and the outcome',
      setUp: () {
        when(
          () => models.download(
            'qwen',
            overMeteredNetwork: any(named: 'overMeteredNetwork'),
            onProgress: any(named: 'onProgress'),
          ),
        ).thenAnswer((invocation) async {
          final report =
              invocation.namedArguments[#onProgress]! as void Function(double);
          report(0.1);
          report(0.101);
          report(0.5);
        });
      },
      build: build,
      seed: () => OnDeviceAiSettingsState(
        status: OnDeviceAiSettingsStatus.ready,
        supported: true,
        models: listed,
      ),
      act: (cubit) => cubit.download('qwen'),
      expect: () => [
        isA<OnDeviceAiSettingsState>().having((s) => s.pending, 'pending', {
          'qwen': OnDeviceModelOperation.download,
        }),
        isA<OnDeviceAiSettingsState>().having((s) => s.progress, 'progress', {
          'qwen': 0.1,
        }),
        isA<OnDeviceAiSettingsState>().having((s) => s.progress, 'progress', {
          'qwen': 0.5,
        }),
        isA<OnDeviceAiSettingsState>()
            .having((s) => s.pending, 'pending', isEmpty)
            .having((s) => s.progress, 'progress', isEmpty)
            .having(
              (s) => s.outcome,
              'outcome',
              const OnDeviceModelOutcome(
                model: 'qwen',
                operation: OnDeviceModelOperation.download,
                succeeded: true,
              ),
            ),
      ],
    );

    blocTest<OnDeviceAiSettingsCubit, OnDeviceAiSettingsState>(
      'a metered network asks first, without an error',
      setUp: () {
        when(
          () => models.download('qwen', onProgress: any(named: 'onProgress')),
        ).thenThrow(const OnDeviceModelMeteredException());
      },
      build: build,
      seed: () => OnDeviceAiSettingsState(supported: true, models: listed),
      act: (cubit) => cubit.download('qwen'),
      errors: () => isEmpty,
      verify: (cubit) {
        expect(cubit.state.outcome!.needsMeteredConsent, isTrue);
        expect(cubit.state.outcome!.succeeded, isFalse);
      },
    );

    blocTest<OnDeviceAiSettingsCubit, OnDeviceAiSettingsState>(
      'ignores unknown models and models that are busy',
      build: build,
      seed: () => OnDeviceAiSettingsState(
        supported: true,
        models: listed,
        pending: const {'qwen': OnDeviceModelOperation.delete},
      ),
      act: (cubit) async {
        await cubit.download('x');
        await cubit.download('qwen');
      },
      expect: () => isEmpty,
    );

    blocTest<OnDeviceAiSettingsCubit, OnDeviceAiSettingsState>(
      'does nothing without on-device AI',
      build: () => OnDeviceAiSettingsCubit(picker: picker),
      act: (cubit) async {
        await cubit.download('qwen');
        await cubit.delete('qwen');
        await cubit.select('qwen');
        await cubit.importFromFiles();
        cubit.cancel('qwen');
      },
      expect: () => isEmpty,
    );

    test('classifies failures', () {
      final mirror = Uri.parse('https://mirror.example/');
      expect(
        OnDeviceModelError.of(const OnDeviceModelTooBigException('x')).kind,
        OnDeviceModelErrorKind.tooBig,
      );
      expect(
        OnDeviceModelError.of(
          LlamaDownloadCancelledException('x', 'stop', mirror: mirror),
        ),
        const OnDeviceModelError(
          OnDeviceModelErrorKind.cancelled,
          mirror: 'mirror.example',
        ),
      );
      expect(
        OnDeviceModelError.of(
          LlamaChecksumException('x', 'bad', mirror: mirror),
        ),
        const OnDeviceModelError(
          OnDeviceModelErrorKind.checksum,
          mirror: 'mirror.example',
        ),
      );
      expect(
        OnDeviceModelError.of(
          LlamaDownloadException('x', 'reset', mirror: mirror),
        ),
        const OnDeviceModelError(
          OnDeviceModelErrorKind.network,
          mirror: 'mirror.example',
        ),
      );
      expect(
        OnDeviceModelError.of(
          LlamaDownloadException('x', 'HTTP', statusCode: 503, mirror: mirror),
        ),
        const OnDeviceModelError(
          OnDeviceModelErrorKind.server,
          statusCode: 503,
          mirror: 'mirror.example',
        ),
      );
      expect(
        OnDeviceModelError.of(const LlamaDownloadException('x', 'reset')).kind,
        OnDeviceModelErrorKind.network,
      );
      expect(
        OnDeviceModelError.of(const FileSystemException('full')).kind,
        OnDeviceModelErrorKind.storage,
      );
      expect(
        OnDeviceModelError.of(StateError('x')).kind,
        OnDeviceModelErrorKind.unknown,
      );
    });

    blocTest<OnDeviceAiSettingsCubit, OnDeviceAiSettingsState>(
      'a failed download goes to addError',
      setUp: () {
        when(
          () => models.download(
            'qwen',
            overMeteredNetwork: any(named: 'overMeteredNetwork'),
            onProgress: any(named: 'onProgress'),
          ),
        ).thenThrow(const LlamaChecksumException('qwen', 'bad'));
      },
      build: build,
      seed: () => OnDeviceAiSettingsState(supported: true, models: listed),
      act: (cubit) => cubit.download('qwen'),
      errors: () => [isA<LlamaChecksumException>()],
      verify: (cubit) => expect(
        cubit.state.outcome!.error!.kind,
        OnDeviceModelErrorKind.checksum,
      ),
    );
  });

  group('cancel', () {
    blocTest<OnDeviceAiSettingsCubit, OnDeviceAiSettingsState>(
      'stops a running download only',
      build: build,
      seed: () => OnDeviceAiSettingsState(
        supported: true,
        models: listed,
        pending: const {
          'qwen': OnDeviceModelOperation.download,
          'hy': OnDeviceModelOperation.delete,
        },
      ),
      act: (cubit) => cubit
        ..cancel('qwen')
        ..cancel('hy')
        ..cancel('x'),
      expect: () => isEmpty,
      verify: (_) {
        verify(() => models.cancelDownload('qwen')).called(1);
        verifyNever(() => models.cancelDownload('hy'));
      },
    );

    blocTest<OnDeviceAiSettingsCubit, OnDeviceAiSettingsState>(
      'a cancelled download is not an error',
      setUp: () {
        when(
          () => models.download(
            'qwen',
            overMeteredNetwork: any(named: 'overMeteredNetwork'),
            onProgress: any(named: 'onProgress'),
          ),
        ).thenThrow(const LlamaDownloadCancelledException('qwen', 'stop'));
      },
      build: build,
      seed: () => OnDeviceAiSettingsState(supported: true, models: listed),
      act: (cubit) => cubit.download('qwen'),
      errors: () => isEmpty,
      verify: (cubit) => expect(
        cubit.state.outcome!.error!.kind,
        OnDeviceModelErrorKind.cancelled,
      ),
    );
  });

  group('delete and select', () {
    blocTest<OnDeviceAiSettingsCubit, OnDeviceAiSettingsState>(
      'deletes a model',
      setUp: () => when(() => models.delete('hy')).thenAnswer((_) async {}),
      build: build,
      seed: () => OnDeviceAiSettingsState(supported: true, models: listed),
      act: (cubit) => cubit.delete('hy'),
      verify: (cubit) {
        verify(() => models.delete('hy')).called(1);
        expect(
          cubit.state.outcome,
          const OnDeviceModelOutcome(
            model: 'hy',
            operation: OnDeviceModelOperation.delete,
            succeeded: true,
          ),
        );
      },
    );

    blocTest<OnDeviceAiSettingsCubit, OnDeviceAiSettingsState>(
      'selects an installed model for its role',
      setUp: () {
        when(() => models.selectAssistantModel('qwen'))
            .thenAnswer((_) async {});
        when(() => models.selectTranslationModel('hy'))
            .thenAnswer((_) async {});
        listed = [entry(hy, installed: true), entry(qwen, installed: true)];
        when(() => models.assistantModel).thenReturn('qwen');
      },
      build: build,
      seed: () => OnDeviceAiSettingsState(
        supported: true,
        models: [entry(hy, installed: true), entry(qwen, installed: true)],
      ),
      act: (cubit) async {
        await cubit.select('qwen');
        await cubit.select('hy');
      },
      verify: (cubit) {
        verify(() => models.selectAssistantModel('qwen')).called(1);
        verify(() => models.selectTranslationModel('hy')).called(1);
        expect(cubit.state.assistantModel, 'qwen');
      },
    );

    blocTest<OnDeviceAiSettingsCubit, OnDeviceAiSettingsState>(
      'ignores models that are not installed, in use or busy',
      build: build,
      seed: () => OnDeviceAiSettingsState(
        supported: true,
        models: [entry(hy, installed: true), entry(qwen)],
        translationModel: 'hy',
      ),
      act: (cubit) async {
        await cubit.select('hy');
        await cubit.select('qwen');
        await cubit.select('x');
      },
      expect: () => isEmpty,
    );

    blocTest<OnDeviceAiSettingsCubit, OnDeviceAiSettingsState>(
      'reports a failed choice',
      setUp: () =>
          when(() => models.selectAssistantModel('qwen'))
              .thenThrow(StateError('store')),
      build: build,
      seed: () => OnDeviceAiSettingsState(
        supported: true,
        models: [entry(qwen, installed: true)],
      ),
      act: (cubit) => cubit.select('qwen'),
      errors: () => [isStateError],
    );
  });

  group('importFromFiles', () {
    blocTest<OnDeviceAiSettingsCubit, OnDeviceAiSettingsState>(
      'imports the picked files and warns about models too big',
      setUp: () {
        when(() => picker.pick(onCopying: any(named: 'onCopying')))
            .thenAnswer((invocation) async {
              (invocation.namedArguments[#onCopying]! as void Function())();
              return ['/cache/hy.gguf', '/cache/qwen.gguf'];
            });
        when(() => models.importFiles(any(), move: any(named: 'move')))
            .thenAnswer(
              (_) async => const OnDeviceImportResult(
                models: {
                  'hy': LlamaImportStatus.installed,
                  'qwen': LlamaImportStatus.installed,
                },
                unmatchedFiles: 1,
              ),
            );
        when(() => models.fitOf(qwen)).thenReturn(OnDeviceFit.tooBig);
      },
      build: () => build(move: true),
      seed: () => OnDeviceAiSettingsState(supported: true, models: listed),
      act: (cubit) => cubit.importFromFiles(),
      verify: (cubit) {
        verify(
          () => models.importFiles([
            '/cache/hy.gguf',
            '/cache/qwen.gguf',
          ], move: true),
        ).called(1);
        verify(() => picker.clearCopies()).called(1);
        expect(cubit.state.importing, isFalse);
        expect(
          cubit.state.importOutcome,
          const OnDeviceImportOutcome(
            models: {
              'hy': LlamaImportStatus.installed,
              'qwen': LlamaImportStatus.installed,
            },
            unmatchedFiles: 1,
            tooBig: {'qwen'},
          ),
        );
      },
    );

    blocTest<OnDeviceAiSettingsCubit, OnDeviceAiSettingsState>(
      'a cancelled picker changes nothing',
      setUp: () =>
          when(() => picker.pick(onCopying: any(named: 'onCopying')))
              .thenAnswer((_) async => []),
      build: build,
      seed: () => OnDeviceAiSettingsState(supported: true, models: listed),
      act: (cubit) => cubit.importFromFiles(),
      expect: () => isEmpty,
    );

    blocTest<OnDeviceAiSettingsCubit, OnDeviceAiSettingsState>(
      'a picker that started copying and then gave nothing stops importing',
      setUp: () =>
          when(() => picker.pick(onCopying: any(named: 'onCopying')))
              .thenAnswer((invocation) async {
                (invocation.namedArguments[#onCopying]! as void Function())();
                return [];
              }),
      build: build,
      seed: () => OnDeviceAiSettingsState(supported: true, models: listed),
      act: (cubit) => cubit.importFromFiles(),
      expect: () => [
        isA<OnDeviceAiSettingsState>().having((s) => s.importing, 'on', true),
        isA<OnDeviceAiSettingsState>().having((s) => s.importing, 'off', false),
      ],
    );

    blocTest<OnDeviceAiSettingsCubit, OnDeviceAiSettingsState>(
      'reports a failed import and a failed clean-up',
      setUp: () {
        when(() => picker.pick(onCopying: any(named: 'onCopying')))
            .thenAnswer((_) async => ['/cache/x.gguf']);
        when(() => models.importFiles(any(), move: any(named: 'move')))
            .thenThrow(const FileSystemException('unreadable'));
        when(() => picker.clearCopies()).thenThrow(StateError('cache'));
      },
      build: build,
      seed: () => OnDeviceAiSettingsState(supported: true, models: listed),
      act: (cubit) => cubit.importFromFiles(),
      errors: () => [isStateError, isA<FileSystemException>()],
      verify: (cubit) => expect(
        cubit.state.importOutcome,
        const OnDeviceImportOutcome(failed: true),
      ),
    );

    blocTest<OnDeviceAiSettingsCubit, OnDeviceAiSettingsState>(
      'does not start twice',
      build: build,
      seed: () => OnDeviceAiSettingsState(
        supported: true,
        models: listed,
        importing: true,
      ),
      act: (cubit) => cubit.importFromFiles(),
      expect: () => isEmpty,
    );
  });

  test('copyWith keeps and clears values', () {
    const state = OnDeviceAiSettingsState(
      translationModel: 'hy',
      assistantModel: 'qwen',
      outcome: OnDeviceModelOutcome(
        model: 'hy',
        operation: OnDeviceModelOperation.delete,
        succeeded: true,
      ),
      importOutcome: OnDeviceImportOutcome(failed: true),
    );
    expect(state.copyWith(), state);
    final cleared = state.copyWith(
      translationModel: () => null,
      assistantModel: () => null,
      outcome: () => null,
      importOutcome: () => null,
    );
    expect(cleared, const OnDeviceAiSettingsState());
  });
}
