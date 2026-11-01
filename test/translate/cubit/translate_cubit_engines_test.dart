import 'dart:async';

import 'package:bloc_test/bloc_test.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:mocktail/mocktail.dart';
import 'package:mozhi/settings/models/app_settings.dart';
import 'package:mozhi/translate/cubit/translate_cubit.dart';
import 'package:translation_repository/translation_repository.dart';

import 'translate_cubit_helpers.dart';

void main() {
  setUpAll(registerTranslateFallbacks);

  late TranslateMocks mocks;

  setUp(() {
    mocks = TranslateMocks();
  });

  group('constructor', () {
    test('seeds languages and options from settings without IO', () {
      mocks.stubSettings(
        const AppSettings(
          source: de,
          target: fr,
          options: TranslationOptions(context: 'chat'),
        ),
      );
      final cubit = mocks.build();
      expect(cubit.state.source, de);
      expect(cubit.state.target, fr);
      expect(cubit.state.options, const TranslationOptions(context: 'chat'));
      expect(cubit.state.enginesStatus, EnginesStatus.initial);
      expect(cubit.debounce, fastDebounce);
      expect(cubit.aiDebounce, fastAiDebounce);
      verifyZeroInteractions(mocks.repository);
    });

    test('uses 600/1200 ms debounce by default', () {
      final cubit = TranslateCubit(
        repository: mocks.repository,
        settings: mocks.settings,
        history: mocks.history,
      );
      expect(cubit.debounce, const Duration(milliseconds: 600));
      expect(cubit.aiDebounce, const Duration(milliseconds: 1200));
    });
  });

  group('loadEngines', () {
    final hallo = resultOf('hallo');

    blocTest<TranslateCubit, TranslateState>(
      'emits loading then ready with Google preferred and the first AI '
      'engine as assist',
      build: () {
        when(() => mocks.repository.getEngines(refresh: any(named: 'refresh')))
            .thenAnswer((_) async => [deepl, google, claude, local]);
        return mocks.build();
      },
      act: (cubit) => cubit.loadEngines(),
      expect: () => [
        const TranslateState(enginesStatus: EnginesStatus.loading),
        const TranslateState(
          enginesStatus: EnginesStatus.ready,
          engines: [deepl, google, claude, local],
          engine: google,
          assistEngine: claude,
          sourceLanguages: sources,
          targetLanguages: targets,
        ),
      ],
      verify: (_) {
        verify(() => mocks.repository.getEngines()).called(1);
        verify(() => mocks.repository.getSourceLanguages(google)).called(1);
        verify(() => mocks.repository.getTargetLanguages(google)).called(1);
      },
    );

    blocTest<TranslateCubit, TranslateState>(
      'passes refresh through',
      build: () => mocks.build(),
      act: (cubit) => cubit.loadEngines(refresh: true),
      verify: (_) {
        verify(() => mocks.repository.getEngines(refresh: true)).called(1);
      },
    );

    blocTest<TranslateCubit, TranslateState>(
      'selects the saved engine and the configured assist engine',
      build: () {
        mocks.stubSettings(
          const AppSettings(
            engineId: 'mozhi:deepl',
            assistEngineId: 'ai:local',
          ),
        );
        when(() => mocks.repository.getEngines(refresh: any(named: 'refresh')))
            .thenAnswer((_) async => [google, deepl, claude, local]);
        return mocks.build();
      },
      act: (cubit) => cubit.loadEngines(),
      verify: (cubit) {
        expect(cubit.state.engine, deepl);
        expect(cubit.state.assistEngine, local);
      },
    );

    blocTest<TranslateCubit, TranslateState>(
      'keeps the previous selection when the saved engine is gone',
      build: () {
        mocks.stubSettings(const AppSettings(engineId: 'mozhi:gone'));
        return mocks.build();
      },
      seed: () => readyState(engine: deepl),
      act: (cubit) => cubit.loadEngines(),
      verify: (cubit) => expect(cubit.state.engine, deepl),
    );

    blocTest<TranslateCubit, TranslateState>(
      'falls back to the first engine without Google; an AI engine is its '
      'own assist engine',
      build: () {
        when(() => mocks.repository.getEngines(refresh: any(named: 'refresh')))
            .thenAnswer((_) async => [local, deepl, claude]);
        return mocks.build();
      },
      act: (cubit) => cubit.loadEngines(),
      verify: (cubit) {
        expect(cubit.state.engine, local);
        expect(cubit.state.assistEngine, local);
        expect(cubit.state.isAiEngine, isTrue);
      },
    );

    blocTest<TranslateCubit, TranslateState>(
      'has no assist engine without AI engines',
      build: () {
        when(() => mocks.repository.getEngines(refresh: any(named: 'refresh')))
            .thenAnswer((_) async => [google, deepl]);
        return mocks.build();
      },
      act: (cubit) => cubit.loadEngines(),
      verify: (cubit) {
        expect(cubit.state.assistEngine, isNull);
        expect(cubit.state.hasExtras, isFalse);
      },
    );

    blocTest<TranslateCubit, TranslateState>(
      'is ready with an empty list when there are no engines',
      build: () {
        when(() => mocks.repository.getEngines(refresh: any(named: 'refresh')))
            .thenAnswer((_) async => []);
        return mocks.build();
      },
      seed: () => readyState(input: 'hi', result: hallo),
      act: (cubit) => cubit.loadEngines(),
      expect: () => [
        readyState(
          input: 'hi',
          result: hallo,
        ).copyWith(enginesStatus: EnginesStatus.loading),
        isA<TranslateState>()
            .having((s) => s.enginesStatus, 'status', EnginesStatus.ready)
            .having((s) => s.engines, 'engines', isEmpty)
            .having((s) => s.engine, 'engine', isNull)
            .having((s) => s.assistEngine, 'assist', isNull)
            .having((s) => s.result, 'result', isNull),
      ],
      verify: (_) {
        verifyNever(() => mocks.repository.getSourceLanguages(any()));
        verifyNever(() => mocks.repository.translate(any(), any()));
      },
    );

    final enginesError = Exception('offline');

    blocTest<TranslateCubit, TranslateState>(
      'emits failure when engines fail to load',
      build: () {
        when(() => mocks.repository.getEngines(refresh: any(named: 'refresh')))
            .thenThrow(enginesError);
        return mocks.build();
      },
      act: (cubit) => cubit.loadEngines(),
      expect: () => [
        const TranslateState(enginesStatus: EnginesStatus.loading),
        TranslateState(
          enginesStatus: EnginesStatus.failure,
          error: enginesError,
        ),
      ],
    );

    blocTest<TranslateCubit, TranslateState>(
      'emits failure but keeps the engines when languages fail to load',
      build: () {
        when(() => mocks.repository.getTargetLanguages(any()))
            .thenThrow(enginesError);
        return mocks.build();
      },
      act: (cubit) => cubit.loadEngines(),
      errors: () => [enginesError],
      verify: (cubit) {
        expect(cubit.state.enginesStatus, EnginesStatus.failure);
        expect(cubit.state.error, enginesError);
        expect(cubit.state.engines, allEngines);
        expect(cubit.state.engine, google);
        expect(cubit.state.assistEngine, claude);
      },
    );

    blocTest<TranslateCubit, TranslateState>(
      'ignores a slower, superseded load',
      setUp: () {
        final slow = Completer<List<TranslationEngine>>();
        var calls = 0;
        when(() => mocks.repository.getEngines(refresh: any(named: 'refresh')))
            .thenAnswer((_) {
              calls++;
              if (calls == 1) {
                Timer(const Duration(milliseconds: 30), () {
                  slow.complete([deepl]);
                });
                return slow.future;
              }
              return Future.value([google, claude]);
            });
      },
      build: () => mocks.build(),
      act: (cubit) async {
        unawaited(cubit.loadEngines());
        await cubit.loadEngines(refresh: true);
        await Future<void>.delayed(const Duration(milliseconds: 60));
      },
      verify: (cubit) {
        expect(cubit.state.engines, [google, claude]);
        expect(cubit.state.engine, google);
        expect(cubit.state.enginesStatus, EnginesStatus.ready);
      },
    );

    blocTest<TranslateCubit, TranslateState>(
      'ignores a superseded load that fails',
      setUp: () {
        var calls = 0;
        when(() => mocks.repository.getEngines(refresh: any(named: 'refresh')))
            .thenAnswer((_) async {
              calls++;
              if (calls == 1) {
                await Future<void>.delayed(const Duration(milliseconds: 30));
                throw Exception('late');
              }
              return [google];
            });
      },
      build: () => mocks.build(),
      act: (cubit) async {
        unawaited(cubit.loadEngines());
        await cubit.loadEngines();
        await Future<void>.delayed(const Duration(milliseconds: 60));
      },
      verify: (cubit) {
        expect(cubit.state.enginesStatus, EnginesStatus.ready);
        expect(cubit.state.error, isNull);
      },
    );

    blocTest<TranslateCubit, TranslateState>(
      'ignores a superseded load when languages arrive late',
      setUp: () {
        var calls = 0;
        when(() => mocks.repository.getSourceLanguages(any()))
            .thenAnswer((_) async {
              calls++;
              if (calls == 1) {
                await Future<void>.delayed(const Duration(milliseconds: 30));
              }
              return sources;
            });
      },
      build: () => mocks.build(),
      act: (cubit) async {
        unawaited(cubit.loadEngines());
        await Future<void>.delayed(Duration.zero);
        await cubit.loadEngines();
        await Future<void>.delayed(const Duration(milliseconds: 60));
      },
      verify: (cubit) {
        verify(() => mocks.repository.getSourceLanguages(any())).called(2);
        expect(cubit.state.enginesStatus, EnginesStatus.ready);
      },
    );

    group('re-maps languages', () {
      blocTest<TranslateCubit, TranslateState>(
        'keeps languages available on the engine',
        build: () {
          mocks.stubSettings(const AppSettings(source: de, target: fr));
          return mocks.build();
        },
        act: (cubit) => cubit.loadEngines(),
        verify: (cubit) {
          expect(cubit.state.source, de);
          expect(cubit.state.target, fr);
        },
      );

      blocTest<TranslateCubit, TranslateState>(
        'falls back to auto / English',
        build: () {
          mocks.stubSettings(const AppSettings(source: ja, target: ja));
          return mocks.build();
        },
        act: (cubit) => cubit.loadEngines(),
        verify: (cubit) {
          expect(cubit.state.source, Language.auto);
          expect(cubit.state.target, en);
        },
      );

      blocTest<TranslateCubit, TranslateState>(
        'falls back to the first languages without auto / English',
        build: () {
          mocks.stubSettings(const AppSettings(source: ja, target: ja));
          when(() => mocks.repository.getSourceLanguages(any()))
              .thenAnswer((_) async => [fr, de]);
          when(() => mocks.repository.getTargetLanguages(any()))
              .thenAnswer((_) async => [es, de]);
          return mocks.build();
        },
        act: (cubit) => cubit.loadEngines(),
        verify: (cubit) {
          expect(cubit.state.source, fr);
          expect(cubit.state.target, es);
        },
      );

      blocTest<TranslateCubit, TranslateState>(
        'uses auto and English for empty lists',
        build: () {
          mocks.stubSettings(const AppSettings(source: ja, target: ja));
          when(() => mocks.repository.getSourceLanguages(any()))
              .thenAnswer((_) async => []);
          when(() => mocks.repository.getTargetLanguages(any()))
              .thenAnswer((_) async => []);
          return mocks.build();
        },
        act: (cubit) => cubit.loadEngines(),
        verify: (cubit) {
          expect(cubit.state.source, Language.auto);
          expect(cubit.state.target, en);
        },
      );

      blocTest<TranslateCubit, TranslateState>(
        'keeps a custom target for AI engines',
        build: () {
          mocks.stubSettings(
            const AppSettings(engineId: 'ai:claude', target: pirate),
          );
          return mocks.build();
        },
        act: (cubit) => cubit.loadEngines(),
        verify: (cubit) => expect(cubit.state.target, pirate),
      );

      blocTest<TranslateCubit, TranslateState>(
        'drops a custom target for Mozhi engines',
        build: () {
          mocks.stubSettings(const AppSettings(target: pirate));
          return mocks.build();
        },
        act: (cubit) => cubit.loadEngines(),
        verify: (cubit) => expect(cubit.state.target, en),
      );
    });

    blocTest<TranslateCubit, TranslateState>(
      'translates pending input once engines are available',
      setUp: () => mocks.stubTranslate(),
      build: () => mocks.build(),
      seed: () => const TranslateState(input: 'hallo'),
      act: (cubit) async {
        await cubit.loadEngines();
        await Future<void>.delayed(Duration.zero);
      },
      verify: (cubit) {
        expect(cubit.state.status, TranslateStatus.success);
        expect(cubit.state.output, 'hallo->en');
        expect(mocks.translateRequests().single.text, 'hallo');
      },
    );

    blocTest<TranslateCubit, TranslateState>(
      'clears the result and re-translates when the engine changed',
      setUp: () {
        mocks.stubTranslate();
        when(() => mocks.repository.getEngines(refresh: any(named: 'refresh')))
            .thenAnswer((_) async => [google, claude]);
      },
      build: () => mocks.build(),
      seed: () => readyState(
        engine: deepl,
        input: 'hallo',
        result: resultOf('old', engine: deepl),
        status: TranslateStatus.success,
      ).copyWith(insightsStatus: ExtraStatus.ready),
      act: (cubit) async {
        await cubit.loadEngines();
        await Future<void>.delayed(Duration.zero);
      },
      verify: (cubit) {
        expect(cubit.state.engine, google);
        expect(cubit.state.output, 'hallo->en');
        expect(cubit.state.insightsStatus, ExtraStatus.idle);
      },
    );

    blocTest<TranslateCubit, TranslateState>(
      'keeps the result when the engine is unchanged',
      setUp: () => mocks.stubTranslate(),
      build: () => mocks.build(),
      seed: () => readyState(
        input: 'hallo',
        result: resultOf('kept'),
        status: TranslateStatus.success,
      ),
      act: (cubit) => cubit.loadEngines(refresh: true),
      verify: (cubit) {
        expect(cubit.state.output, 'kept');
        verifyNever(() => mocks.repository.translate(any(), any()));
      },
    );
  });

  group('selectEngine', () {
    blocTest<TranslateCubit, TranslateState>(
      'persists the engine, reloads languages and clears the result',
      build: () => mocks.build(),
      seed: () => readyState(
        result: resultOf('old'),
        status: TranslateStatus.success,
      ).copyWith(explanation: 'md', explainStatus: ExtraStatus.ready),
      act: (cubit) => cubit.selectEngine(claude),
      expect: () => [
        readyState(engine: claude),
        readyState(engine: claude).copyWith(
          sourceLanguages: [Language.auto, en, ja],
          targetLanguages: [en, ja],
        ),
      ],
      setUp: () {
        when(() => mocks.repository.getSourceLanguages(claude))
            .thenAnswer((_) async => [Language.auto, en, ja]);
        when(() => mocks.repository.getTargetLanguages(claude))
            .thenAnswer((_) async => [en, ja]);
      },
      verify: (_) {
        verify(() => mocks.settings.setEngine('ai:claude')).called(1);
        verifyNever(() => mocks.repository.translate(any(), any()));
      },
    );

    blocTest<TranslateCubit, TranslateState>(
      'uses the first AI engine as assist when switching to Mozhi',
      build: () => mocks.build(),
      seed: () => readyState(engine: claude),
      act: (cubit) => cubit.selectEngine(deepl),
      verify: (cubit) {
        expect(cubit.state.engine, deepl);
        expect(cubit.state.assistEngine, claude);
      },
    );

    blocTest<TranslateCubit, TranslateState>(
      're-maps languages and re-translates non-empty input',
      setUp: () {
        mocks.stubTranslate();
        when(() => mocks.repository.getTargetLanguages(deepl))
            .thenAnswer((_) async => [en, de]);
      },
      build: () => mocks.build(),
      seed: () => readyState(
        engine: claude,
        input: 'hi',
        target: pirate,
        result: resultOf('Ahoy', engine: claude),
        status: TranslateStatus.success,
      ),
      act: (cubit) => cubit.selectEngine(deepl),
      verify: (cubit) {
        expect(cubit.state.target, en);
        expect(cubit.state.output, 'hi->en');
        expect(cubit.state.result?.engineId, deepl.id);
        expect(cubit.state.status, TranslateStatus.success);
      },
    );

    blocTest<TranslateCubit, TranslateState>(
      'does nothing for the selected engine',
      build: () => mocks.build(),
      seed: readyState,
      act: (cubit) => cubit.selectEngine(google),
      expect: () => <TranslateState>[],
      verify: (_) => verifyNever(() => mocks.settings.setEngine(any())),
    );

    final languagesError = Exception('languages');

    blocTest<TranslateCubit, TranslateState>(
      'emits failure when languages fail and does not translate',
      setUp: () {
        mocks.stubTranslate();
        when(() => mocks.repository.getSourceLanguages(deepl))
            .thenThrow(languagesError);
      },
      build: () => mocks.build(),
      seed: () => readyState(input: 'hi'),
      act: (cubit) => cubit.selectEngine(deepl),
      verify: (cubit) {
        expect(cubit.state.enginesStatus, EnginesStatus.failure);
        expect(cubit.state.error, languagesError);
        verifyNever(() => mocks.repository.translate(any(), any()));
      },
    );

    blocTest<TranslateCubit, TranslateState>(
      'ignores a superseded switch',
      setUp: () {
        mocks.stubTranslate();
        when(() => mocks.repository.getSourceLanguages(deepl))
            .thenAnswer((_) async {
              await Future<void>.delayed(const Duration(milliseconds: 30));
              return [Language.auto, de];
            });
        when(() => mocks.repository.getTargetLanguages(deepl))
            .thenAnswer((_) async {
              await Future<void>.delayed(const Duration(milliseconds: 30));
              throw languagesError;
            });
      },
      build: () => mocks.build(),
      seed: () => readyState(input: 'hi'),
      act: (cubit) async {
        unawaited(cubit.selectEngine(deepl));
        await cubit.selectEngine(claude);
        await Future<void>.delayed(const Duration(milliseconds: 60));
      },
      verify: (cubit) {
        expect(cubit.state.engine, claude);
        expect(cubit.state.enginesStatus, EnginesStatus.ready);
        expect(cubit.state.sourceLanguages, sources);
        final requests = verify(
          () => mocks.repository.translate(captureAny(), any()),
        ).captured;
        expect(requests, [claude]);
      },
    );

    blocTest<TranslateCubit, TranslateState>(
      'ignores languages of a superseded switch',
      setUp: () {
        when(() => mocks.repository.getSourceLanguages(deepl))
            .thenAnswer((_) async {
              await Future<void>.delayed(const Duration(milliseconds: 30));
              return [Language.auto, de];
            });
      },
      build: () => mocks.build(),
      seed: readyState,
      act: (cubit) async {
        unawaited(cubit.selectEngine(deepl));
        await cubit.selectEngine(claude);
        await Future<void>.delayed(const Duration(milliseconds: 60));
      },
      verify: (cubit) {
        expect(cubit.state.engine, claude);
        expect(cubit.state.sourceLanguages, sources);
      },
    );
  });

  group('reloadEnginesIfNeeded', () {
    test('lists the engines again, quietly, when the Mozhi list could not be '
        'loaded', () async {
      when(() => mocks.repository.getEngines(refresh: any(named: 'refresh')))
          .thenAnswer((_) async => const [claude]);
      when(() => mocks.repository.mozhiEnginesNeedReload).thenReturn(true);
      final cubit = mocks.build();
      addTearDown(cubit.close);
      mocks.stubSettings(const AppSettings(engineId: 'ai:claude'));
      await cubit.loadEngines();
      expect(cubit.state.engines, const [claude]);

      // Back to the front with the network: the Mozhi engines come back.
      when(() => mocks.repository.getEngines(refresh: any(named: 'refresh')))
          .thenAnswer((_) async => allEngines);
      final statuses = <EnginesStatus>[];
      final subscription = cubit.stream.listen(
        (state) => statuses.add(state.enginesStatus),
      );
      addTearDown(subscription.cancel);
      await cubit.reloadEnginesIfNeeded();

      expect(cubit.state.engines, allEngines);
      expect(cubit.state.engine, claude);
      expect(statuses, isNot(contains(EnginesStatus.loading)));
      verify(() => mocks.repository.getEngines(refresh: any(named: 'refresh')))
          .called(2);
    });

    test('does nothing when the lists loaded', () async {
      when(() => mocks.repository.mozhiEnginesNeedReload).thenReturn(false);
      final cubit = mocks.build();
      addTearDown(cubit.close);
      await cubit.loadEngines();
      await cubit.reloadEnginesIfNeeded();
      verify(() => mocks.repository.getEngines(refresh: any(named: 'refresh')))
          .called(1);
    });

    test('does nothing with a repository that cannot tell', () async {
      final cubit = mocks.build();
      addTearDown(cubit.close);
      await cubit.loadEngines();
      await cubit.reloadEnginesIfNeeded();
      verify(() => mocks.repository.getEngines(refresh: any(named: 'refresh')))
          .called(1);
    });
  });

  group('translate while the engines load', () {
    const manual = AppSettings(
      engineId: 'mozhi:google',
      instantTranslate: false,
      instantTranslateAi: false,
    );

    test('runs once an engine is ready instead of being dropped', () async {
      final engines = Completer<List<TranslationEngine>>();
      when(() => mocks.repository.getEngines(refresh: any(named: 'refresh')))
          .thenAnswer((_) => engines.future);
      mocks
        ..stubSettings(manual)
        ..stubTranslate();
      final cubit = mocks.build();
      addTearDown(cubit.close);
      unawaited(cubit.loadEngines());
      cubit.setInput('Hallo');

      var done = false;
      unawaited(cubit.translate().then((_) => done = true));
      await Future<void>.delayed(Duration.zero);
      verifyNever(() => mocks.repository.translate(any(), any()));
      expect(done, isFalse);

      engines.complete(allEngines);
      await Future<void>.delayed(afterDebounce);

      final request = mocks.translateRequests().single;
      expect(request.text, 'Hallo');
      expect(cubit.state.output, 'Hallo->en');
      expect(done, isTrue);
    });

    test('is let go when the engines fail to load', () async {
      final engines = Completer<List<TranslationEngine>>();
      when(() => mocks.repository.getEngines(refresh: any(named: 'refresh')))
          .thenAnswer((_) => engines.future);
      mocks
        ..stubSettings(manual)
        ..stubTranslate();
      final cubit = mocks.build();
      addTearDown(cubit.close);
      unawaited(cubit.loadEngines());
      cubit.setInput('Hallo');
      final pending = cubit.translate();

      engines.completeError(const MozhiApiException('offline'));
      await pending;

      verifyNever(() => mocks.repository.translate(any(), any()));
      expect(cubit.state.enginesStatus, EnginesStatus.failure);
    });

    test('is let go when the cubit closes', () async {
      when(() => mocks.repository.getEngines(refresh: any(named: 'refresh')))
          .thenAnswer((_) => Completer<List<TranslationEngine>>().future);
      mocks.stubSettings(manual);
      final cubit = mocks.build();
      unawaited(cubit.loadEngines());
      cubit.setInput('Hallo');
      final pending = cubit.translate();
      await cubit.close();
      await expectLater(pending, completes);
    });
  });
}
