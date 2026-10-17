import 'dart:async';

import 'package:bergamot_translator/bergamot_translator.dart'
    show MeteredConnectionException;
import 'package:bloc_test/bloc_test.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:mocktail/mocktail.dart';
import 'package:mozhi/core/key_value_store.dart';
import 'package:mozhi/image_translate/image_translate.dart';
import 'package:mozhi/offline/data/offline_model_error.dart';
import 'package:tesseract_ocr/tesseract_ocr.dart'
    show TessdataDownloadException;

import '../../offline/helpers.dart';
import '../helpers/fake_ocr.dart';

void main() {
  late FakeOcrData data;
  late MemoryStore store;

  setUp(() {
    data = FakeOcrData();
    store = MemoryStore();
  });

  OcrOfferCubit build({MockOfflineModelFilePicker? picker}) => OcrOfferCubit(
    data: data,
    language: deuOcr,
    store: store,
    picker: picker ?? stubOfflineModelFilePicker(paths: const []),
  );

  group('download', () {
    blocTest<OcrOfferCubit, OcrOfferState>(
      'downloads over Wi-Fi only by default, with progress',
      setUp: () => data.progressSteps = const [0.25, 0.251, 1],
      build: build,
      act: (cubit) => cubit.download(),
      expect: () => const [
        OcrOfferState(status: OcrOfferStatus.downloading),
        OcrOfferState(status: OcrOfferStatus.downloading, progress: 0.25),
        OcrOfferState(status: OcrOfferStatus.downloading, progress: 1),
        OcrOfferState(status: OcrOfferStatus.installed),
      ],
      verify: (_) => expect(data.downloads, [(code: 'deu', wifiOnly: true)]),
    );

    blocTest<OcrOfferCubit, OcrOfferState>(
      'honours Wi-Fi only switched off',
      setUp: () => store.values['offline.wifiOnly'] = 'false',
      build: build,
      act: (cubit) => cubit.download(),
      verify: (_) => expect(data.downloads.single.wifiOnly, isFalse),
    );

    blocTest<OcrOfferCubit, OcrOfferState>(
      'stops on a metered network and downloads anyway when asked',
      setUp: () => data.downloadError = const MeteredConnectionException(),
      build: build,
      act: (cubit) async {
        await cubit.download();
        data.downloadError = null;
        await cubit.download(overMeteredNetwork: true);
      },
      expect: () => const [
        OcrOfferState(status: OcrOfferStatus.downloading),
        OcrOfferState(error: OfflineModelError(OfflineModelErrorKind.metered)),
        OcrOfferState(status: OcrOfferStatus.downloading),
        OcrOfferState(status: OcrOfferStatus.installed),
      ],
      verify: (_) => expect(data.downloads, [
        (code: 'deu', wifiOnly: true),
        (code: 'deu', wifiOnly: false),
      ]),
    );

    blocTest<OcrOfferCubit, OcrOfferState>(
      'reports failures',
      setUp: () => data.downloadError = const TessdataDownloadException(
        'deu',
        'offline',
      ),
      build: build,
      act: (cubit) => cubit.download(),
      expect: () => const [
        OcrOfferState(status: OcrOfferStatus.downloading),
        OcrOfferState(error: OfflineModelError(OfflineModelErrorKind.network)),
      ],
      errors: () => [isA<TessdataDownloadException>()],
    );

    blocTest<OcrOfferCubit, OcrOfferState>(
      'does nothing while busy or once installed',
      build: build,
      seed: () => const OcrOfferState(status: OcrOfferStatus.installed),
      act: (cubit) async {
        await cubit.download();
        await cubit.importFromFiles();
      },
      expect: () => const <OcrOfferState>[],
    );

    blocTest<OcrOfferCubit, OcrOfferState>(
      'reads Wi-Fi only as on when the store fails',
      build: () =>
          OcrOfferCubit(data: data, language: deuOcr, store: _FailingStore()),
      act: (cubit) => cubit.download(),
      errors: () => [isA<StateError>()],
      verify: (_) => expect(data.downloads.single.wifiOnly, isTrue),
    );
  });

  group('importFromFiles', () {
    blocTest<OcrOfferCubit, OcrOfferState>(
      'installs the picked file without the network',
      build: () => build(
        picker: stubOfflineModelFilePicker(
          paths: const ['/picked/deu.traineddata'],
          copies: true,
        ),
      ),
      act: (cubit) => cubit.importFromFiles(),
      expect: () => const [
        OcrOfferState(status: OcrOfferStatus.importing),
        OcrOfferState(status: OcrOfferStatus.installed),
      ],
      verify: (_) {
        expect(data.imported.single, ['/picked/deu.traineddata']);
        expect(data.downloads, isEmpty);
      },
    );

    blocTest<OcrOfferCubit, OcrOfferState>(
      'counts data that was already installed',
      setUp: () =>
          data.importReport = const OcrImportReport(alreadyInstalled: ['deu']),
      build: () =>
          build(picker: stubOfflineModelFilePicker(paths: const ['/picked/x'])),
      act: (cubit) => cubit.importFromFiles(),
      expect: () => const [
        OcrOfferState(status: OcrOfferStatus.importing),
        OcrOfferState(status: OcrOfferStatus.installed),
      ],
    );

    blocTest<OcrOfferCubit, OcrOfferState>(
      'reports files that do not install the language',
      setUp: () => data.importReport = const OcrImportReport(damaged: ['deu']),
      build: () => build(
        picker: stubOfflineModelFilePicker(paths: const ['/picked/deu']),
      ),
      act: (cubit) => cubit.importFromFiles(),
      expect: () => const [
        OcrOfferState(status: OcrOfferStatus.importing),
        OcrOfferState(importReport: OcrImportReport(damaged: ['deu'])),
      ],
    );

    blocTest<OcrOfferCubit, OcrOfferState>(
      'changes nothing when the picker is cancelled',
      build: build,
      act: (cubit) => cubit.importFromFiles(),
      expect: () => const [OcrOfferState()],
    );

    blocTest<OcrOfferCubit, OcrOfferState>(
      'reports import errors',
      setUp: () => data.importError = Exception('unreadable'),
      build: () => build(
        picker: stubOfflineModelFilePicker(paths: const ['/picked/deu']),
      ),
      act: (cubit) => cubit.importFromFiles(),
      expect: () => [
        const OcrOfferState(status: OcrOfferStatus.importing),
        isA<OcrOfferState>()
            .having((s) => s.status, 'status', OcrOfferStatus.idle)
            .having((s) => s.importReport?.error, 'error', isA<Exception>()),
      ],
      errors: () => [isA<Exception>()],
    );

    blocTest<OcrOfferCubit, OcrOfferState>(
      'reports failures to clear the picked copies',
      build: () {
        final picker = stubOfflineModelFilePicker(
          paths: const ['/picked/deu.traineddata'],
        );
        when(picker.clearCopies).thenThrow(StateError('busy'));
        return build(picker: picker);
      },
      act: (cubit) => cubit.importFromFiles(),
      errors: () => [isA<StateError>()],
      verify: (cubit) => expect(cubit.state.status, OcrOfferStatus.installed),
    );
  });

  blocTest<OcrOfferCubit, OcrOfferState>(
    'becomes installed when the data is installed elsewhere',
    build: build,
    act: (cubit) async {
      data.installElsewhere('eng');
      await pumpEventQueue();
      data.installElsewhere('deu');
      await pumpEventQueue();
    },
    expect: () => const [OcrOfferState(status: OcrOfferStatus.installed)],
  );

  blocTest<OcrOfferCubit, OcrOfferState>(
    'reports errors while checking an outside change',
    build: build,
    act: (cubit) async {
      data
        ..installedError = Exception('io')
        ..installElsewhere('deu');
      await pumpEventQueue();
    },
    expect: () => const <OcrOfferState>[],
    errors: () => [isA<Exception>()],
  );

  test('state helpers', () {
    expect(const OcrOfferState().isBusy, isFalse);
    expect(
      const OcrOfferState(status: OcrOfferStatus.importing).isBusy,
      isTrue,
    );
    expect(
      const OcrOfferState(progress: 0.5).copyWith(),
      const OcrOfferState(progress: 0.5),
    );
  });

  test('a running download is not cut short by an outside change', () async {
    data.downloadGate = Completer<void>();
    final cubit = build();
    addTearDown(cubit.close);
    final download = cubit.download();
    await pumpEventQueue();
    data.installElsewhere('deu');
    await pumpEventQueue();
    expect(cubit.state.status, OcrOfferStatus.downloading);
    data.downloadGate!.complete();
    await download;
    expect(cubit.state.status, OcrOfferStatus.installed);
  });
}

class _FailingStore implements KeyValueStore {
  @override
  Future<String?> read(String key) => throw StateError('locked');

  @override
  Future<void> write(String key, String value) async {}

  @override
  Future<void> delete(String key) async {}
}
