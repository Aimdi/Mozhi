import 'dart:async';

import 'package:bergamot_translator/bergamot_translator.dart'
    show MeteredConnectionException;
import 'package:bloc_test/bloc_test.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:mocktail/mocktail.dart';
import 'package:mozhi/core/key_value_store.dart';
import 'package:mozhi/image_translate/image_translate.dart';
import 'package:mozhi/offline/data/offline_model_error.dart';
import 'package:mozhi/offline/offline.dart';
import 'package:tesseract_ocr/tesseract_ocr.dart'
    show TessdataChecksumException;

import '../../image_translate/helpers/fake_ocr.dart';
import '../helpers.dart';

void main() {
  late FakeOcrData data;
  late MemoryStore store;

  setUp(() {
    data = FakeOcrData(installed: {'deu': 1525436});
    store = MemoryStore();
  });

  OcrLanguagesCubit build({MockOfflineModelFilePicker? picker}) =>
      OcrLanguagesCubit(
        data: data,
        store: store,
        picker: picker ?? stubOfflineModelFilePicker(paths: const []),
      );

  Future<OcrLanguagesCubit> loaded({MockOfflineModelFilePicker? picker}) async {
    final cubit = build(picker: picker);
    addTearDown(cubit.close);
    await cubit.load();
    return cubit;
  }

  group('load', () {
    test('names and sorts the languages, with what is installed', () async {
      final cubit = await loaded();
      final state = cubit.state;
      expect(state.status, OfflineModelsStatus.ready);
      expect(state.isAvailable, isTrue);
      expect(
        [for (final item in state.languages) item.display.name],
        ['Chinese (Simplified)', 'English', 'French', 'German', 'Japanese'],
      );
      expect(state.item('deu')?.display.code, 'de');
      expect(state.item('xxx'), isNull);
      expect(state.installed, {'deu': 1525436});
      expect(state.totalBytes, 1525436);
      expect([for (final i in state.visibleInstalled) i.code], ['deu']);
      expect(state.visibleAvailable, hasLength(4));
      expect(state.wifiOnly, isTrue);
    });

    test('reads Wi-Fi only from the shared setting', () async {
      store.values[OfflineModelsCubit.wifiOnlyKey] = 'false';
      final cubit = await loaded();
      expect(cubit.state.wifiOnly, isFalse);
    });

    test('lists nothing as installed where recognition cannot run', () async {
      data.isSupported = false;
      final cubit = await loaded();
      expect(cubit.state.isAvailable, isFalse);
      expect(cubit.state.installed, isEmpty);
      await cubit.importFromFiles();
      expect(cubit.state.importing, isFalse);
    });

    blocTest<OcrLanguagesCubit, OcrLanguagesState>(
      'fails when the catalog cannot be read',
      setUp: () => data.languagesError = Exception('no assets'),
      build: build,
      act: (cubit) => cubit.load(),
      expect: () => const [
        OcrLanguagesState(status: OfflineModelsStatus.loading),
        OcrLanguagesState(status: OfflineModelsStatus.failure),
      ],
      errors: () => [isA<Exception>()],
    );
  });

  group('download', () {
    test('downloads with progress and reports the outcome', () async {
      data.progressSteps = const [0.5, 0.501, 1];
      final cubit = await loaded();
      final states = <OcrLanguagesState>[];
      final subscription = cubit.stream.listen(states.add);
      addTearDown(subscription.cancel);

      await cubit.download('fra');
      await pumpEventQueue();

      expect(states.first.pending, {'fra': OfflineModelOperation.download});
      expect([for (final s in states) s.progress['fra']].whereType<double>(), [
        0.5,
        1,
      ]);
      expect(cubit.state.isInstalled('fra'), isTrue);
      expect(cubit.state.pending, isEmpty);
      expect(cubit.state.progress, isEmpty);
      expect(cubit.state.outcome?.succeeded, isTrue);
      expect(cubit.state.outcome?.language.name, 'French');
      expect(data.downloads, [(code: 'fra', wifiOnly: true)]);
    });

    test(
      'a metered network asks; anyway downloads without Wi-Fi only',
      () async {
        data.downloadError = const MeteredConnectionException();
        final cubit = await loaded();
        await cubit.download('fra');
        expect(cubit.state.outcome?.needsMeteredConsent, isTrue);
        data.downloadError = null;
        await cubit.download('fra', overMeteredNetwork: true);
        expect(data.downloads.last, (code: 'fra', wifiOnly: false));
      },
    );

    test('reports a damaged download', () async {
      data.downloadError = const TessdataChecksumException('fra', 'bad');
      final cubit = await loaded();
      await cubit.download('fra');
      expect(cubit.state.outcome?.succeeded, isFalse);
      expect(
        cubit.state.outcome?.error,
        const OfflineModelError(OfflineModelErrorKind.checksum),
      );
    });

    test('ignores a second request while one runs', () async {
      data.downloadGate = Completer<void>();
      final cubit = await loaded();
      final first = cubit.download('fra');
      await pumpEventQueue();
      await cubit.download('fra');
      data.downloadGate!.complete();
      await first;
      expect(data.downloads, hasLength(1));
    });
  });

  test('delete removes the data', () async {
    final cubit = await loaded();
    await cubit.delete('deu');
    expect(data.deleted, ['deu']);
    expect(cubit.state.installed, isEmpty);
    expect(cubit.state.outcome?.operation, OfflineModelOperation.delete);
  });

  test('setWifiOnly persists the shared setting', () async {
    final cubit = await loaded();
    await cubit.setWifiOnly(enabled: false);
    expect(cubit.state.wifiOnly, isFalse);
    expect(store.values[OfflineModelsCubit.wifiOnlyKey], 'false');
  });

  test('search filters by name, native name or code', () async {
    final cubit = await loaded();
    cubit.search('JAP');
    expect([for (final i in cubit.state.visible) i.code], ['jpn']);
    cubit.search('chi_sim');
    expect([for (final i in cubit.state.visible) i.code], ['chi_sim']);
    cubit.search(' ');
    expect(cubit.state.visible, hasLength(5));
  });

  group('importFromFiles', () {
    test('installs picked files and reports them', () async {
      final cubit = await loaded(
        picker: stubOfflineModelFilePicker(
          paths: const ['/picked/fra.traineddata'],
          copies: true,
        ),
      );
      await cubit.importFromFiles();
      expect(cubit.state.importing, isFalse);
      expect(
        cubit.state.importOutcome,
        const OcrImportReport(installed: ['fra']),
      );
      expect(cubit.state.isInstalled('fra'), isTrue);
    });

    test('changes nothing when cancelled', () async {
      final cubit = await loaded();
      await cubit.importFromFiles();
      expect(cubit.state.importOutcome, isNull);
      expect(cubit.state.importing, isFalse);
    });

    test('reports a failed import', () async {
      data.importError = Exception('unreadable');
      final cubit = await loaded(
        picker: stubOfflineModelFilePicker(paths: const ['/picked/x']),
      );
      await cubit.importFromFiles();
      expect(cubit.state.importOutcome?.error, isA<Exception>());
    });

    blocTest<OcrLanguagesCubit, OcrLanguagesState>(
      'reports a failure to clear the picked copies',
      build: () {
        final picker = stubOfflineModelFilePicker(paths: const ['/p/x']);
        when(picker.clearCopies).thenThrow(StateError('busy'));
        return build(picker: picker);
      },
      act: (cubit) async {
        await cubit.load();
        await cubit.importFromFiles();
      },
      errors: () => [isA<StateError>()],
      verify: (cubit) => expect(cubit.state.importOutcome, isNotNull),
    );
  });

  test('picks up changes made elsewhere', () async {
    final cubit = await loaded();
    data.installElsewhere('jpn');
    await pumpEventQueue();
    expect(cubit.state.isInstalled('jpn'), isTrue);
  });

  test('keeps the last known data when reading it fails', () async {
    final cubit = await loaded();
    data.installedError = Exception('io');
    await cubit.download('fra');
    expect(cubit.state.installed, {'deu': 1525436});
  });

  test('OcrLanguageItem matches its code too', () {
    const item = OcrLanguageItem(
      ocr: deuOcr,
      display: OfflineLanguage(code: 'de', name: 'German'),
    );
    expect(item.matches('deu'), isTrue);
    expect(item.matches('germ'), isTrue);
    expect(item.matches('fra'), isFalse);
  });
}
