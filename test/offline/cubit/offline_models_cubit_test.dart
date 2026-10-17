import 'dart:async';
import 'dart:io';

import 'package:bergamot_translator/bergamot_translator.dart';
import 'package:bloc_test/bloc_test.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:mocktail/mocktail.dart';
import 'package:mozhi/core/key_value_store.dart';
import 'package:mozhi/offline/data/offline_model_details.dart';
import 'package:mozhi/offline/data/offline_model_error.dart';
import 'package:mozhi/offline/offline.dart';
import 'package:translation_repository/translation_repository.dart';

import '../helpers.dart';

class _MockStore extends Mock implements KeyValueStore;

OfflineLanguage _describe(String code) => OfflineLanguage(
  code: code,
  name: switch (code) {
    'de' => 'German',
    'en' => 'English',
    'fr' => 'French',
    'ja' => 'Japanese',
    _ => code,
  },
);

void main() {
  late MockOfflineTranslator translator;
  late MemoryStore store;

  final german = _describe('de');
  final english = _describe('en');
  final french = _describe('fr');
  final japanese = _describe('ja');
  final unknown = _describe('xx');

  setUp(() {
    translator = stubOfflineTranslator();
    store = MemoryStore();
  });

  OfflineModelsCubit build({KeyValueStore? withStore}) => OfflineModelsCubit(
    translator: translator,
    store: withStore ?? store,
    describe: _describe,
  );

  OfflineModelsState ready({
    Set<String> downloaded = const {'en', 'de'},
    bool wifiOnly = true,
  }) => OfflineModelsState(
    status: OfflineModelsStatus.ready,
    languages: [english, french, german, japanese, unknown],
    downloaded: downloaded,
    wifiOnly: wifiOnly,
  );

  group('OfflineModelsCubit', () {
    test('starts in the initial state', () {
      expect(build().state, const OfflineModelsState());
    });

    group('load', () {
      blocTest<OfflineModelsCubit, OfflineModelsState>(
        'lists languages sorted by name with the downloaded ones',
        build: build,
        act: (cubit) => cubit.load(),
        expect: () => [
          const OfflineModelsState(status: OfflineModelsStatus.loading),
          ready(),
        ],
      );

      blocTest<OfflineModelsCubit, OfflineModelsState>(
        'reads the persisted Wi-Fi only choice',
        setUp: () => store.values[OfflineModelsCubit.wifiOnlyKey] = 'false',
        build: build,
        act: (cubit) => cubit.load(),
        skip: 1,
        expect: () => [ready(wifiOnly: false)],
      );

      blocTest<OfflineModelsCubit, OfflineModelsState>(
        'does not query models when the engine is unavailable',
        setUp: () => translator = stubOfflineTranslator(available: false),
        build: build,
        act: (cubit) => cubit.load(),
        skip: 1,
        expect: () => [
          ready(downloaded: const {}).copyWith(isAvailable: false),
        ],
        verify: (_) => verifyNever(translator.downloadedLanguages),
      );

      blocTest<OfflineModelsCubit, OfflineModelsState>(
        'switches to failure when the models cannot be listed',
        setUp: () =>
            when(translator.downloadedLanguages)
                .thenThrow(StateError('no plugin')),
        build: build,
        act: (cubit) => cubit.load(),
        expect: () => [
          const OfflineModelsState(status: OfflineModelsStatus.loading),
          const OfflineModelsState(status: OfflineModelsStatus.failure),
        ],
        errors: () => [isStateError],
      );

      final failingStore = _MockStore();
      blocTest<OfflineModelsCubit, OfflineModelsState>(
        'defaults to Wi-Fi only when the store fails',
        setUp: () =>
            when(() => failingStore.read(any())).thenThrow(Exception('store')),
        build: () => build(withStore: failingStore),
        act: (cubit) => cubit.load(),
        skip: 1,
        expect: () => [ready()],
        errors: () => [isException],
      );

      test('does not emit after close', () async {
        final completer = Completer<Set<String>>();
        when(translator.downloadedLanguages)
            .thenAnswer((_) => completer.future);
        final cubit = build();
        final loading = cubit.load();
        await cubit.close();
        completer.complete({'en'});
        await loading;
        expect(cubit.state.status, OfflineModelsStatus.loading);
      });

      test('does not emit a failure after close', () async {
        final completer = Completer<Set<String>>();
        when(translator.downloadedLanguages)
            .thenAnswer((_) => completer.future);
        final cubit = build();
        final loading = cubit.load();
        await cubit.close();
        completer.completeError(StateError('late'));
        await loading;
        expect(cubit.state.status, OfflineModelsStatus.loading);
      });
    });

    group('download', () {
      blocTest<OfflineModelsCubit, OfflineModelsState>(
        'downloads over Wi-Fi only by default and reports success',
        build: build,
        seed: ready,
        act: (cubit) => cubit.download('fr'),
        expect: () => [
          ready().copyWith(pending: {'fr': OfflineModelOperation.download}),
          ready(downloaded: {'en', 'de', 'fr'}).copyWith(
            outcome: () => OfflineModelOutcome(
              language: french,
              operation: OfflineModelOperation.download,
              succeeded: true,
            ),
          ),
        ],
        verify: (_) =>
            verify(() => translator.downloadLanguage('fr')).called(1),
      );

      blocTest<OfflineModelsCubit, OfflineModelsState>(
        'honours wifiOnly: false',
        build: build,
        seed: () => ready(wifiOnly: false),
        act: (cubit) => cubit.download('ja'),
        verify: (_) =>
            verify(() => translator.downloadLanguage('ja', wifiOnly: false))
                .called(1),
      );

      blocTest<OfflineModelsCubit, OfflineModelsState>(
        'reports failures',
        setUp: () => when(
          () => translator.downloadLanguage(
            any(),
            wifiOnly: any(named: 'wifiOnly'),
          ),
        ).thenThrow(Exception('network')),
        build: build,
        seed: ready,
        act: (cubit) => cubit.download('fr'),
        expect: () => [
          ready().copyWith(pending: {'fr': OfflineModelOperation.download}),
          ready().copyWith(
            outcome: () => OfflineModelOutcome(
              language: french,
              operation: OfflineModelOperation.download,
              succeeded: false,
              error: const OfflineModelError(OfflineModelErrorKind.unknown),
            ),
          ),
        ],
        errors: () => [isException],
      );

      blocTest<OfflineModelsCubit, OfflineModelsState>(
        'ignores a language that is already busy',
        build: build,
        seed: () =>
            ready().copyWith(pending: {'fr': OfflineModelOperation.download}),
        act: (cubit) => cubit.download('fr'),
        expect: () => <OfflineModelsState>[],
        verify: (_) => verifyNever(
          () => translator.downloadLanguage(
            any(),
            wifiOnly: any(named: 'wifiOnly'),
          ),
        ),
      );

      blocTest<OfflineModelsCubit, OfflineModelsState>(
        'clears the previous outcome when a new operation starts',
        build: build,
        seed: () => ready().copyWith(
          outcome: () => OfflineModelOutcome(
            language: french,
            operation: OfflineModelOperation.download,
            succeeded: false,
          ),
        ),
        act: (cubit) => cubit.download('fr'),
        expect: () => [
          ready().copyWith(pending: {'fr': OfflineModelOperation.download}),
          isA<OfflineModelsState>().having(
            (s) => s.outcome?.succeeded,
            'succeeded',
            isTrue,
          ),
        ],
      );

      blocTest<OfflineModelsCubit, OfflineModelsState>(
        'describes languages that were not loaded yet',
        build: build,
        act: (cubit) => cubit.download('ja'),
        skip: 1,
        expect: () => [
          isA<OfflineModelsState>().having(
            (s) => s.outcome?.language,
            'language',
            japanese,
          ),
        ],
      );

      test('does not emit after close', () async {
        final completer = Completer<void>();
        when(
          () => translator.downloadLanguage(
            any(),
            wifiOnly: any(named: 'wifiOnly'),
          ),
        ).thenAnswer((_) => completer.future);
        final cubit = build();
        final download = cubit.download('fr');
        await cubit.close();
        completer.complete();
        await download;
        expect(cubit.state.pending, {'fr': OfflineModelOperation.download});
      });
    });

    group('delete', () {
      blocTest<OfflineModelsCubit, OfflineModelsState>(
        'deletes the model and reports success',
        build: build,
        seed: ready,
        act: (cubit) => cubit.delete('de'),
        expect: () => [
          ready().copyWith(pending: {'de': OfflineModelOperation.delete}),
          ready(downloaded: {'en'}).copyWith(
            outcome: () => OfflineModelOutcome(
              language: german,
              operation: OfflineModelOperation.delete,
              succeeded: true,
            ),
          ),
        ],
        verify: (_) => verify(() => translator.deleteLanguage('de')).called(1),
      );

      blocTest<OfflineModelsCubit, OfflineModelsState>(
        'reports failures',
        setUp: () =>
            when(() => translator.deleteLanguage(any()))
                .thenThrow(Exception('busy')),
        build: build,
        seed: ready,
        act: (cubit) => cubit.delete('de'),
        skip: 1,
        expect: () => [
          ready().copyWith(
            outcome: () => OfflineModelOutcome(
              language: german,
              operation: OfflineModelOperation.delete,
              succeeded: false,
              error: const OfflineModelError(OfflineModelErrorKind.unknown),
            ),
          ),
        ],
        errors: () => [isException],
      );
    });

    group('setWifiOnly', () {
      blocTest<OfflineModelsCubit, OfflineModelsState>(
        'updates and persists the choice',
        build: build,
        seed: ready,
        act: (cubit) => cubit.setWifiOnly(enabled: false),
        expect: () => [ready(wifiOnly: false)],
        verify: (_) =>
            expect(store.values[OfflineModelsCubit.wifiOnlyKey], 'false'),
      );

      final failingStore = _MockStore();
      blocTest<OfflineModelsCubit, OfflineModelsState>(
        'keeps the choice when it cannot be saved',
        setUp: () =>
            when(() => failingStore.write(any(), any()))
                .thenThrow(Exception('store')),
        build: () => build(withStore: failingStore),
        seed: ready,
        act: (cubit) => cubit.setWifiOnly(enabled: false),
        expect: () => [ready(wifiOnly: false)],
        errors: () => [isException],
      );
    });

    blocTest<OfflineModelsCubit, OfflineModelsState>(
      'search updates the query',
      build: build,
      seed: ready,
      act: (cubit) => cubit.search('ger'),
      expect: () => [ready().copyWith(query: 'ger')],
    );
  });

  group('OfflineModelsCubit with details', () {
    late FakeOfflineModelDetails details;

    setUp(() => details = FakeOfflineModelDetails());

    OfflineModelsCubit buildWithDetails() => OfflineModelsCubit(
      translator: translator,
      store: store,
      details: details,
      describe: _describe,
    );

    OfflineModelsState readyWithDetails({
      Set<String> downloaded = const {'en', 'de'},
      OfflineStorage? storage = testStorage,
    }) =>
        ready(downloaded: downloaded)
            .copyWith(downloadSizes: testDownloadSizes, storage: () => storage);

    blocTest<OfflineModelsCubit, OfflineModelsState>(
      'loads download sizes and the storage',
      build: buildWithDetails,
      act: (cubit) => cubit.load(),
      skip: 1,
      expect: () => [readyWithDetails()],
      verify: (cubit) {
        expect(cubit.state.isBuiltIn('en'), isTrue);
        expect(cubit.state.downloadedCount, 1);
        expect(cubit.state.installedSizeOf('de'), testStorage.totalBytes);
      },
    );

    blocTest<OfflineModelsCubit, OfflineModelsState>(
      'stays usable when the storage cannot be read',
      setUp: () => details.storageError = const FileSystemException('denied'),
      build: buildWithDetails,
      act: (cubit) => cubit.load(),
      skip: 1,
      expect: () => [readyWithDetails(storage: null)],
      errors: () => [isA<FileSystemException>()],
    );

    blocTest<OfflineModelsCubit, OfflineModelsState>(
      'reads no storage where the engine is unavailable',
      setUp: () => translator = stubOfflineTranslator(available: false),
      build: buildWithDetails,
      act: (cubit) => cubit.load(),
      skip: 1,
      expect: () => [
        readyWithDetails(
          downloaded: const {},
          storage: null,
        ).copyWith(isAvailable: false),
      ],
      verify: (_) => expect(details.storageCalls, 0),
    );

    blocTest<OfflineModelsCubit, OfflineModelsState>(
      'reports progress in whole percents and re-reads the models',
      setUp: () {
        details
          ..progressSteps = [0.001, 0.005, 0.5, 0.504, 1]
          ..storageAfterDownload = const OfflineStorage(
            installedBytes: {'de': 70, 'fr': 50},
            totalBytes: 120,
          );
        when(translator.downloadedLanguages)
            .thenAnswer((_) async => {'en', 'de', 'fr'});
      },
      build: buildWithDetails,
      seed: readyWithDetails,
      act: (cubit) => cubit.download('fr'),
      expect: () {
        final pending = readyWithDetails().copyWith(
          pending: {'fr': OfflineModelOperation.download},
        );
        return [
          pending,
          pending.copyWith(progress: {'fr': 0.001}),
          pending.copyWith(progress: {'fr': 0.5}),
          pending.copyWith(progress: {'fr': 1}),
          readyWithDetails(
            downloaded: {'en', 'de', 'fr'},
            storage: const OfflineStorage(
              installedBytes: {'de': 70, 'fr': 50},
              totalBytes: 120,
            ),
          ).copyWith(
            outcome: () => OfflineModelOutcome(
              language: french,
              operation: OfflineModelOperation.download,
              succeeded: true,
            ),
          ),
        ];
      },
      verify: (_) {
        expect(details.downloads, [('fr', true)]);
        verifyNever(
          () => translator.downloadLanguage(
            any(),
            wifiOnly: any(named: 'wifiOnly'),
          ),
        );
      },
    );

    blocTest<OfflineModelsCubit, OfflineModelsState>(
      'updates outdated languages',
      build: buildWithDetails,
      seed: () => readyWithDetails(
        storage: const OfflineStorage(
          installedBytes: {'de': 70},
          totalBytes: 70,
          outdated: {'de'},
        ),
      ),
      act: (cubit) => cubit.download('de'),
      expect: () => [
        isA<OfflineModelsState>().having((s) => s.pending, 'pending', {
          'de': OfflineModelOperation.update,
        }),
        isA<OfflineModelsState>()
            .having(
              (s) => s.outcome?.operation,
              'operation',
              OfflineModelOperation.update,
            )
            .having((s) => s.isOutdated('de'), 'outdated', isFalse),
      ],
    );

    blocTest<OfflineModelsCubit, OfflineModelsState>(
      'asks before a download over a metered network, then downloads anyway',
      setUp: () => details.error = const MeteredConnectionException(),
      build: buildWithDetails,
      seed: readyWithDetails,
      act: (cubit) async {
        await cubit.download('ja');
        expect(cubit.state.outcome?.needsMeteredConsent, isTrue);
        details.error = null;
        await cubit.download('ja', overMeteredNetwork: true);
      },
      skip: 1,
      expect: () => [
        readyWithDetails().copyWith(
          outcome: () => OfflineModelOutcome(
            language: japanese,
            operation: OfflineModelOperation.download,
            succeeded: false,
            error: const OfflineModelError(OfflineModelErrorKind.metered),
          ),
        ),
        readyWithDetails().copyWith(
          pending: {'ja': OfflineModelOperation.download},
        ),
        isA<OfflineModelsState>().having(
          (s) => s.outcome?.succeeded,
          'succeeded',
          isTrue,
        ),
      ],
      // A metered network is not an error.
      errors: () => <Object>[],
      verify: (_) => expect(details.downloads, [('ja', true), ('ja', false)]),
    );

    blocTest<OfflineModelsCubit, OfflineModelsState>(
      'classifies download failures',
      setUp: () =>
          details.error = const ModelChecksumException('en-fr', 'bad hash'),
      build: buildWithDetails,
      seed: readyWithDetails,
      act: (cubit) => cubit.download('fr'),
      skip: 1,
      expect: () => [
        readyWithDetails().copyWith(
          outcome: () => OfflineModelOutcome(
            language: french,
            operation: OfflineModelOperation.download,
            succeeded: false,
            error: const OfflineModelError(OfflineModelErrorKind.checksum),
          ),
        ),
      ],
      errors: () => [isA<ModelChecksumException>()],
    );

    blocTest<OfflineModelsCubit, OfflineModelsState>(
      'falls back to its own bookkeeping when the models cannot be re-read',
      setUp: () =>
          when(translator.downloadedLanguages).thenThrow(StateError('gone')),
      build: buildWithDetails,
      seed: readyWithDetails,
      act: (cubit) => cubit.delete('de'),
      skip: 1,
      expect: () => [
        readyWithDetails(downloaded: {'en'}).copyWith(
          outcome: () => OfflineModelOutcome(
            language: german,
            operation: OfflineModelOperation.delete,
            succeeded: true,
          ),
        ),
      ],
      errors: () => [isStateError],
    );

    test('ignores progress after a download or once closed', () async {
      final cubit = buildWithDetails()..emit(readyWithDetails());
      await cubit.download('fr');
      final done = cubit.state;
      details.lastOnProgress!(0.7);
      expect(cubit.state, done);

      details.hold = Completer<void>();
      final download = cubit.download('ja');
      await pumpEventQueue();
      await cubit.close();
      details.lastOnProgress!(0.3);
      details.hold!.complete();
      await download;
      expect(cubit.state.progress, isEmpty);
    });
  });

  group('describeOfflineLanguage', () {
    test('uses the catalogue names', () {
      expect(
        describeOfflineLanguage('de'),
        const OfflineLanguage(
          code: 'de',
          name: 'German',
          nativeName: 'Deutsch',
        ),
      );
    });

    test('drops a native name equal to the English name', () {
      expect(
        describeOfflineLanguage(
          'af',
          lookup: (_) => const Language(
            code: 'af',
            name: 'Afrikaans',
            nativeName: 'Afrikaans',
          ),
        ).nativeName,
        isNull,
      );
    });

    test('falls back to the code for unknown languages', () {
      expect(
        describeOfflineLanguage('xx-unknown'),
        const OfflineLanguage(code: 'xx-unknown', name: 'xx-unknown'),
      );
    });

    test('falls back to the code when the lookup throws', () {
      expect(
        describeOfflineLanguage(
          'de',
          lookup: (_) => throw UnimplementedError(),
        ),
        const OfflineLanguage(code: 'de', name: 'de'),
      );
    });
  });
}
