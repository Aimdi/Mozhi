import 'dart:async';

import 'package:bloc_test/bloc_test.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:mocktail/mocktail.dart';
import 'package:mozhi/core/key_value_store.dart';
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
