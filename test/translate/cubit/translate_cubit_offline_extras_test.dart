import 'package:bloc_test/bloc_test.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:mocktail/mocktail.dart';
import 'package:mozhi/translate/cubit/translate_cubit.dart';
import 'package:translation_repository/translation_repository.dart';

import 'translate_cubit_helpers.dart';

void main() {
  setUpAll(registerTranslateFallbacks);

  late TranslateMocks mocks;

  setUp(() {
    mocks = TranslateMocks();
  });

  final device = TranslationEngine.offline();
  final engines = [google, claude, device];

  TranslationResult resultBy(TranslationEngine engine) => TranslationResult(
    engineId: engine.id,
    engineName: engine.name,
    text: 'Hallo Welt',
  );

  TranslateState translated({
    required TranslationEngine engine,
    TranslationEngine? assistEngine = claude,
    TranslationResult? result,
  }) => readyState(
    engine: engine,
    assistEngine: assistEngine,
    engines: engines,
    input: 'Hello world',
    source: en,
    target: de,
    result: result ?? resultBy(engine),
    status: TranslateStatus.success,
  );

  group('TranslateState.alignmentEngine', () {
    test('is the on-device engine for its own translations', () {
      final state = translated(engine: device);
      expect(state.alignmentEngine, device);
      expect(state.canAlign, isTrue);
    });

    test('is the on-device engine when it translated after a fallback', () {
      final state = translated(engine: google, result: resultBy(device));
      expect(state.alignmentEngine, device);
    });

    test('is the on-device engine when selected, before a result', () {
      final state = readyState(
        engine: device,
        assistEngine: null,
        engines: engines,
      );
      expect(state.alignmentEngine, device);
      expect(state.canAlign, isFalse);
    });

    test('is the AI assist engine for other translations', () {
      expect(translated(engine: google).alignmentEngine, claude);
    });

    test('is null without an assist engine or an on-device result', () {
      final state = translated(engine: google, assistEngine: null);
      expect(state.alignmentEngine, isNull);
      expect(state.canAlign, isFalse);
    });
  });

  group('loadAlignment with the on-device engine', () {
    const spans = [
      AlignedSpan(sourceStart: 0, sourceEnd: 5, targetStart: 0, targetEnd: 5),
    ];

    blocTest<TranslateCubit, TranslateState>(
      'aligns with the engine that translated, not the AI',
      setUp: () {
        when(
          () => mocks.repository.align(
            any(),
            source: any(named: 'source'),
            translation: any(named: 'translation'),
            sourceLanguage: any(named: 'sourceLanguage'),
            targetLanguage: any(named: 'targetLanguage'),
          ),
        ).thenAnswer((_) async => spans);
      },
      build: () => mocks.build(),
      seed: () => translated(engine: device),
      act: (cubit) => cubit.loadAlignment(),
      expect: () => [
        translated(engine: device)
            .copyWith(alignmentStatus: ExtraStatus.loading),
        translated(engine: device)
            .copyWith(alignmentStatus: ExtraStatus.ready, alignment: spans),
      ],
      verify: (_) {
        verify(
          () => mocks.repository.align(
            device,
            source: 'Hello world',
            translation: 'Hallo Welt',
            sourceLanguage: en,
            targetLanguage: de,
          ),
        ).called(1);
        verifyNever(
          () => mocks.repository.align(
            claude,
            source: any(named: 'source'),
            translation: any(named: 'translation'),
            sourceLanguage: any(named: 'sourceLanguage'),
            targetLanguage: any(named: 'targetLanguage'),
          ),
        );
      },
    );
  });

  group('preloading the on-device models', () {
    void stubPreload() {
      when(
        () => mocks.repository.preloadOffline(
          any(),
          source: any(named: 'source'),
          target: any(named: 'target'),
        ),
      ).thenAnswer((_) async => true);
    }

    blocTest<TranslateCubit, TranslateState>(
      'preloads each pair once while the on-device engine is selected',
      setUp: stubPreload,
      build: () => mocks.build(),
      seed: () => readyState(engine: device, engines: engines),
      act: (cubit) => cubit
        ..setSource(en)
        ..setTarget(fr)
        ..setTarget(de)
        ..setTarget(fr),
      verify: (_) {
        verify(
          () => mocks.repository.preloadOffline(device, source: en, target: fr),
        ).called(2);
        verify(
          () => mocks.repository.preloadOffline(device, source: en, target: en),
        ).called(1);
        verify(
          () => mocks.repository.preloadOffline(device, source: en, target: de),
        ).called(1);
      },
    );

    blocTest<TranslateCubit, TranslateState>(
      'does not preload for an automatic source or another engine',
      setUp: stubPreload,
      build: () => mocks.build(),
      seed: () => readyState(engines: engines),
      act: (cubit) => cubit
        ..setSource(en)
        ..setTarget(fr),
      verify: (_) => verifyNever(
        () => mocks.repository.preloadOffline(
          any(),
          source: any(named: 'source'),
          target: any(named: 'target'),
        ),
      ),
    );

    blocTest<TranslateCubit, TranslateState>(
      'ignores a repository without preloading',
      build: () => mocks.build(),
      seed: () => readyState(engine: device, engines: engines),
      act: (cubit) => cubit.setSource(en),
      errors: () => isEmpty,
    );
  });
}
