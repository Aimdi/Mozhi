import 'dart:async';
import 'dart:io';

import 'package:bloc_test/bloc_test.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:mocktail/mocktail.dart';
import 'package:mozhi/core/key_value_store.dart';
import 'package:mozhi/offline/data/offline_model_details.dart';
import 'package:mozhi/offline/data/offline_model_error.dart';
import 'package:mozhi/offline/data/offline_model_import.dart';
import 'package:mozhi/offline/offline.dart';

import '../helpers.dart';

OfflineLanguage _describe(String code) => OfflineLanguage(
  code: code,
  name: switch (code) {
    'de' => 'German',
    'en' => 'English',
    'fr' => 'French',
    'ja' => 'Japanese',
    'hbs' => 'Serbo-Croatian',
    _ => code,
  },
);

void main() {
  late MockOfflineTranslator translator;
  late MemoryStore store;
  late FakeImportingModelDetails details;
  late MockOfflineModelFilePicker picker;

  final german = _describe('de');
  final english = _describe('en');
  final french = _describe('fr');
  final japanese = _describe('ja');
  final unknown = _describe('xx');

  const path = '/picked/model.deen.intgemm.alphas.bin.gz';

  setUp(() {
    translator = stubOfflineTranslator();
    store = MemoryStore();
    details = FakeImportingModelDetails();
    picker = stubOfflineModelFilePicker();
  });

  OfflineModelsCubit build({OfflineModelDetails? withDetails}) =>
      OfflineModelsCubit(
        translator: translator,
        store: store,
        details: withDetails ?? details,
        picker: picker,
        describe: _describe,
      );

  final manual = {
    'de': [
      OfflineManualDirection(
        source: german,
        target: english,
        files: [testManualFiles['de']!.first],
      ),
      OfflineManualDirection(
        source: english,
        target: german,
        files: [testManualFiles['de']!.last],
      ),
    ],
  };

  OfflineModelsState ready({
    Set<String> downloaded = const {'en', 'de'},
    OfflineStorage? storage = testStorage,
  }) => OfflineModelsState(
    status: OfflineModelsStatus.ready,
    languages: [english, french, german, japanese, unknown],
    downloaded: downloaded,
    downloadSizes: testDownloadSizes,
    storage: storage,
    canImport: true,
    manualDownloads: manual,
  );

  group('OfflineModelsCubit load with imports', () {
    blocTest<OfflineModelsCubit, OfflineModelsState>(
      'allows imports and lists the files to download by hand',
      build: build,
      act: (cubit) => cubit.load(),
      skip: 1,
      expect: () => [ready()],
      verify: (cubit) {
        expect(cubit.state.manualDownloadsOf('de'), manual['de']);
        expect(cubit.state.manualDownloadsOf('fr'), isEmpty);
      },
    );

    blocTest<OfflineModelsCubit, OfflineModelsState>(
      'names languages that are not in the list',
      setUp: () => details.manual = {
        'fr': const [
          OfflineModelFile(
            source: 'hbs',
            target: 'en',
            name: 'model.hbsen.intgemm.alphas.bin.gz',
            url: 'https://models.test/hbs-en/model.hbsen.intgemm.alphas.bin.gz',
            size: 1,
          ),
        ],
      },
      build: build,
      act: (cubit) => cubit.load(),
      skip: 1,
      verify: (cubit) {
        final [direction] = cubit.state.manualDownloadsOf('fr');
        expect(direction.source, _describe('hbs'));
        expect(direction.target, english);
        expect(cubit.state.manualDownloadsOf('de'), isEmpty);
      },
    );

    blocTest<OfflineModelsCubit, OfflineModelsState>(
      'offers no import where the engine is unavailable',
      setUp: () => translator = stubOfflineTranslator(available: false),
      build: build,
      act: (cubit) => cubit.load(),
      skip: 1,
      verify: (cubit) => expect(cubit.state.canImport, isFalse),
    );

    blocTest<OfflineModelsCubit, OfflineModelsState>(
      'offers no import when the details cannot import',
      build: () => build(withDetails: FakeOfflineModelDetails()),
      act: (cubit) => cubit.load(),
      skip: 1,
      verify: (cubit) {
        expect(cubit.state.canImport, isFalse);
        expect(cubit.state.manualDownloads, isEmpty);
      },
    );

    blocTest<OfflineModelsCubit, OfflineModelsState>(
      'uses an importer given on its own',
      build: () => OfflineModelsCubit(
        translator: translator,
        store: store,
        importer: details,
        picker: picker,
        describe: _describe,
      ),
      act: (cubit) => cubit.load(),
      skip: 1,
      verify: (cubit) {
        expect(cubit.state.canImport, isTrue);
        expect(cubit.state.manualDownloadsOf('de'), manual['de']);
      },
    );
  });

  group('OfflineModelsCubit.importFromFiles', () {
    const report = OfflineImportReport(
      models: [
        OfflineImportedModel(
          source: 'de',
          target: 'en',
          status: OfflineImportStatus.installed,
        ),
        OfflineImportedModel(
          source: 'en',
          target: 'de',
          status: OfflineImportStatus.incomplete,
          missingFiles: ['vocab.ende.spm.gz'],
        ),
        OfflineImportedModel(
          source: 'hbs',
          target: 'en',
          status: OfflineImportStatus.failed,
          error: OfflineModelError(OfflineModelErrorKind.storage),
        ),
      ],
      unmatchedFiles: ['notes.txt'],
    );
    const after = OfflineStorage(
      installedBytes: {'de': 70, 'fr': 50},
      totalBytes: 120,
    );
    final outcome = OfflineImportOutcome(
      entries: [
        OfflineImportEntry(
          source: german,
          target: english,
          status: OfflineImportStatus.installed,
        ),
        OfflineImportEntry(
          source: english,
          target: german,
          status: OfflineImportStatus.incomplete,
          missingFiles: const ['vocab.ende.spm.gz'],
        ),
        OfflineImportEntry(
          source: _describe('hbs'),
          target: english,
          status: OfflineImportStatus.failed,
          error: const OfflineModelError(OfflineModelErrorKind.storage),
        ),
      ],
      unmatchedFiles: const ['notes.txt'],
    );

    void succeed() {
      details
        ..report = report
        ..storageAfterImport = after;
      when(translator.downloadedLanguages)
          .thenAnswer((_) async => {'en', 'de', 'fr'});
    }

    blocTest<OfflineModelsCubit, OfflineModelsState>(
      'installs the picked files and reports what happened',
      setUp: succeed,
      build: build,
      seed: ready,
      act: (cubit) => cubit.importFromFiles(),
      expect: () => [
        ready().copyWith(importing: true),
        ready(
          downloaded: const {'en', 'de', 'fr'},
          storage: after,
        ).copyWith(importOutcome: () => outcome),
      ],
      verify: (cubit) {
        expect(details.imports, [
          [path],
        ]);
        verify(picker.clearCopies).called(1);
        expect(cubit.state.importOutcome?.installedAny, isTrue);
      },
    );

    blocTest<OfflineModelsCubit, OfflineModelsState>(
      'shows progress once while the platform copies the files',
      setUp: () {
        succeed();
        picker = stubOfflineModelFilePicker(copies: true);
      },
      build: build,
      seed: ready,
      act: (cubit) => cubit.importFromFiles(),
      expect: () => [
        ready().copyWith(importing: true),
        ready(
          downloaded: const {'en', 'de', 'fr'},
          storage: after,
        ).copyWith(importOutcome: () => outcome),
      ],
    );

    blocTest<OfflineModelsCubit, OfflineModelsState>(
      'clears the previous outcome when a new import starts',
      setUp: succeed,
      build: build,
      seed: () => ready().copyWith(importOutcome: () => outcome),
      act: (cubit) => cubit.importFromFiles(),
      expect: () => [
        ready().copyWith(importing: true),
        ready(
          downloaded: const {'en', 'de', 'fr'},
          storage: after,
        ).copyWith(importOutcome: () => outcome),
      ],
    );

    blocTest<OfflineModelsCubit, OfflineModelsState>(
      'changes nothing when the picker is cancelled',
      setUp: () => picker = stubOfflineModelFilePicker(paths: const []),
      build: build,
      seed: ready,
      act: (cubit) => cubit.importFromFiles(),
      expect: () => <OfflineModelsState>[],
      verify: (_) {
        expect(details.imports, isEmpty);
        verifyNever(picker.clearCopies);
      },
    );

    blocTest<OfflineModelsCubit, OfflineModelsState>(
      'stops the progress when nothing was picked after all',
      setUp: () =>
          picker = stubOfflineModelFilePicker(paths: const [], copies: true),
      build: build,
      seed: ready,
      act: (cubit) => cubit.importFromFiles(),
      expect: () => [ready().copyWith(importing: true), ready()],
    );

    blocTest<OfflineModelsCubit, OfflineModelsState>(
      'reports a picker failure',
      setUp: () =>
          when(() => picker.pick(onCopying: any(named: 'onCopying')))
              .thenThrow(Exception('no picker')),
      build: build,
      seed: ready,
      act: (cubit) => cubit.importFromFiles(),
      expect: () => [
        ready().copyWith(
          importOutcome: () => const OfflineImportOutcome(
            error: OfflineModelError(OfflineModelErrorKind.unknown),
          ),
        ),
      ],
      errors: () => [isException],
    );

    blocTest<OfflineModelsCubit, OfflineModelsState>(
      'reports a failed import and still clears the copies',
      setUp: () => details.importError = const FileSystemException('full'),
      build: build,
      seed: ready,
      act: (cubit) => cubit.importFromFiles(),
      expect: () => [
        ready().copyWith(importing: true),
        ready().copyWith(
          importOutcome: () => const OfflineImportOutcome(
            error: OfflineModelError(OfflineModelErrorKind.storage),
          ),
        ),
      ],
      errors: () => [isA<FileSystemException>()],
      verify: (cubit) {
        verify(picker.clearCopies).called(1);
        expect(cubit.state.importOutcome?.installedAny, isFalse);
      },
    );

    blocTest<OfflineModelsCubit, OfflineModelsState>(
      'reports the outcome when the copies cannot be cleared',
      setUp: () {
        succeed();
        when(picker.clearCopies).thenThrow(Exception('busy'));
      },
      build: build,
      seed: ready,
      act: (cubit) => cubit.importFromFiles(),
      expect: () => [
        ready().copyWith(importing: true),
        ready(
          downloaded: const {'en', 'de', 'fr'},
          storage: after,
        ).copyWith(importOutcome: () => outcome),
      ],
      errors: () => [isException],
    );

    blocTest<OfflineModelsCubit, OfflineModelsState>(
      'keeps the last known languages when they cannot be re-read',
      setUp: () =>
          when(translator.downloadedLanguages).thenThrow(StateError('plugin')),
      build: build,
      seed: ready,
      act: (cubit) => cubit.importFromFiles(),
      expect: () => [
        ready().copyWith(importing: true),
        ready().copyWith(importOutcome: () => const OfflineImportOutcome()),
      ],
      errors: () => [isStateError],
    );

    blocTest<OfflineModelsCubit, OfflineModelsState>(
      'does nothing while an import runs',
      build: build,
      seed: () => ready().copyWith(importing: true),
      act: (cubit) => cubit.importFromFiles(),
      expect: () => <OfflineModelsState>[],
      verify: (_) =>
          verifyNever(() => picker.pick(onCopying: any(named: 'onCopying'))),
    );

    blocTest<OfflineModelsCubit, OfflineModelsState>(
      'does nothing where imports are not possible',
      build: build,
      seed: () => ready().copyWith(canImport: false),
      act: (cubit) => cubit.importFromFiles(),
      expect: () => <OfflineModelsState>[],
    );

    blocTest<OfflineModelsCubit, OfflineModelsState>(
      'does nothing without an importer',
      build: () => build(withDetails: FakeOfflineModelDetails()),
      seed: ready,
      act: (cubit) => cubit.importFromFiles(),
      expect: () => <OfflineModelsState>[],
      verify: (_) =>
          verifyNever(() => picker.pick(onCopying: any(named: 'onCopying'))),
    );

    test('does not emit after close', () async {
      succeed();
      details.importHold = Completer<void>();
      final cubit = build();
      await cubit.load();
      final future = cubit.importFromFiles();
      await pumpEventQueue();
      expect(cubit.state.importing, isTrue);

      await cubit.close();
      details.importHold!.complete();
      await future;
      expect(cubit.state.importing, isTrue);
      expect(cubit.state.importOutcome, isNull);
    });
  });
}
