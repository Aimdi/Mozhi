import 'package:bloc_test/bloc_test.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:mocktail/mocktail.dart';
import 'package:mozhi/translate/cubit/translate_cubit.dart';
import 'package:translation_repository/translation_repository.dart';

import 'translate_cubit_helpers.dart';

/// The result area's block of the cubit (Wave 2): the sentences the
/// on-device engine is unsure about, and other translations of a short
/// input.
void main() {
  setUpAll(registerTranslateFallbacks);

  late TranslateMocks mocks;

  setUp(() {
    mocks = TranslateMocks();
  });

  final device = TranslationEngine.offline();
  final engines = [google, claude, device];

  const unsure = [
    AlignedSpan(sourceStart: 10, sourceEnd: 18, targetStart: 11, targetEnd: 22),
  ];

  TranslationResult resultBy(TranslationEngine engine) => TranslationResult(
    engineId: engine.id,
    engineName: engine.name,
    text: 'Guten Tag. Böser Hund.',
  );

  TranslateState translated({
    required TranslationEngine engine,
    TranslationResult? result,
    String input = 'Good day. Bad dog.',
    Language source = en,
  }) => readyState(
    engine: engine,
    engines: engines,
    input: input,
    source: source,
    target: de,
    result: result ?? resultBy(engine),
    status: TranslateStatus.success,
  );

  void stubUnsure([List<AlignedSpan> spans = unsure]) => when(
    () => mocks.repository.lowConfidenceSentences(
      any(),
      source: any(named: 'source'),
      translation: any(named: 'translation'),
      sourceLanguage: any(named: 'sourceLanguage'),
      targetLanguage: any(named: 'targetLanguage'),
    ),
  ).thenAnswer((_) async => spans);

  group('TranslateState.lowConfidenceSentences', () {
    test('are the sentences found for the shown, current result', () {
      final state = translated(engine: device).copyWith(
        uncertainSentences: unsure,
        uncertainResult: () => resultBy(device),
      );
      expect(state.lowConfidenceSentences, unsure);
    });

    test('are empty for another result or an edited input', () {
      final state = translated(engine: device).copyWith(
        uncertainSentences: unsure,
        uncertainResult: () => resultBy(google),
      );
      expect(state.lowConfidenceSentences, isEmpty);
      final edited = translated(engine: device).copyWith(
        uncertainSentences: unsure,
        uncertainResult: () => resultBy(device),
        input: 'Good day. Bad cat.',
      );
      expect(edited.lowConfidenceSentences, isEmpty);
      expect(translated(engine: device).lowConfidenceSentences, isEmpty);
    });

    test('keeps them in copyWith and compares them', () {
      final state = translated(engine: device).copyWith(
        uncertainSentences: unsure,
        uncertainResult: () => resultBy(device),
      );
      expect(state.copyWith(input: state.input), state);
      expect(state.copyWith(uncertainResult: () => null), isNot(state));
      expect(state.copyWith(uncertainSentences: const []), isNot(state));
    });
  });

  group('loadUncertainty', () {
    blocTest<TranslateCubit, TranslateState>(
      'finds the unsure sentences of an on-device translation',
      setUp: stubUnsure,
      build: () => mocks.build(),
      seed: () => translated(engine: device),
      act: (cubit) => cubit.loadUncertainty(),
      expect: () => [
        translated(engine: device).copyWith(
          uncertainSentences: unsure,
          uncertainResult: () => resultBy(device),
        ),
      ],
      verify: (_) {
        verify(
          () => mocks.repository.lowConfidenceSentences(
            device,
            source: 'Good day. Bad dog.',
            translation: 'Guten Tag. Böser Hund.',
            sourceLanguage: en,
            targetLanguage: de,
          ),
        ).called(1);
      },
    );

    blocTest<TranslateCubit, TranslateState>(
      'uses the detected source language',
      setUp: stubUnsure,
      build: () => mocks.build(),
      seed: () => translated(
        engine: device,
        source: Language.auto,
        result: TranslationResult(
          engineId: device.id,
          engineName: device.name,
          text: 'Guten Tag. Böser Hund.',
          detectedSource: 'en',
        ),
      ),
      act: (cubit) => cubit.loadUncertainty(),
      verify: (_) {
        verify(
          () => mocks.repository.lowConfidenceSentences(
            device,
            source: any(named: 'source'),
            translation: any(named: 'translation'),
            sourceLanguage: en,
            targetLanguage: de,
          ),
        ).called(1);
      },
    );

    blocTest<TranslateCubit, TranslateState>(
      'also after the on-device engine translated as a fallback',
      setUp: stubUnsure,
      build: () => mocks.build(),
      seed: () => translated(engine: google, result: resultBy(device)),
      act: (cubit) => cubit.loadUncertainty(),
      expect: () => [
        translated(engine: google, result: resultBy(device)).copyWith(
          uncertainSentences: unsure,
          uncertainResult: () => resultBy(device),
        ),
      ],
    );

    blocTest<TranslateCubit, TranslateState>(
      'never for other engines: nothing is sent',
      setUp: stubUnsure,
      build: () => mocks.build(),
      seed: () => translated(engine: google),
      act: (cubit) => cubit.loadUncertainty(),
      expect: () => const <TranslateState>[],
      verify: (_) => verifyNever(
        () => mocks.repository.lowConfidenceSentences(
          any(),
          source: any(named: 'source'),
          translation: any(named: 'translation'),
          sourceLanguage: any(named: 'sourceLanguage'),
          targetLanguage: any(named: 'targetLanguage'),
        ),
      ),
    );

    blocTest<TranslateCubit, TranslateState>(
      'not for an unfinished, failed or out-of-date translation',
      setUp: stubUnsure,
      build: () => mocks.build(),
      act: (cubit) async {
        cubit.emit(
          translated(engine: device)
              .copyWith(status: TranslateStatus.translating),
        );
        await cubit.loadUncertainty();
        cubit.emit(
          translated(engine: device).copyWith(
            result: () => resultBy(device).copyWith(isComplete: false),
          ),
        );
        await cubit.loadUncertainty();
        cubit.emit(translated(engine: device).copyWith(input: 'Edited.'));
        await cubit.loadUncertainty();
        cubit.emit(translated(engine: device).copyWith(result: () => null));
        await cubit.loadUncertainty();
      },
      verify: (_) => verifyNever(
        () => mocks.repository.lowConfidenceSentences(
          any(),
          source: any(named: 'source'),
          translation: any(named: 'translation'),
          sourceLanguage: any(named: 'sourceLanguage'),
          targetLanguage: any(named: 'targetLanguage'),
        ),
      ),
    );

    blocTest<TranslateCubit, TranslateState>(
      'does nothing when they are known',
      setUp: stubUnsure,
      build: () => mocks.build(),
      seed: () => translated(engine: device).copyWith(
        uncertainSentences: unsure,
        uncertainResult: () => resultBy(device),
      ),
      act: (cubit) => cubit.loadUncertainty(),
      expect: () => const <TranslateState>[],
    );

    blocTest<TranslateCubit, TranslateState>(
      'emits nothing when no sentence is unsure',
      setUp: () => stubUnsure(const []),
      build: () => mocks.build(),
      seed: () => translated(engine: device),
      act: (cubit) => cubit.loadUncertainty(),
      expect: () => const <TranslateState>[],
    );

    blocTest<TranslateCubit, TranslateState>(
      'ignores errors',
      setUp: () => when(
        () => mocks.repository.lowConfidenceSentences(
          any(),
          source: any(named: 'source'),
          translation: any(named: 'translation'),
          sourceLanguage: any(named: 'sourceLanguage'),
          targetLanguage: any(named: 'targetLanguage'),
        ),
      ).thenThrow(const OfflineLanguageUnsupportedException('de')),
      build: () => mocks.build(),
      seed: () => translated(engine: device),
      act: (cubit) => cubit.loadUncertainty(),
      expect: () => const <TranslateState>[],
    );

    blocTest<TranslateCubit, TranslateState>(
      'drops sentences found for a result that was replaced meanwhile',
      setUp: stubUnsure,
      build: () => mocks.build(),
      seed: () => translated(engine: device),
      act: (cubit) {
        final load = cubit.loadUncertainty();
        cubit.emit(
          translated(engine: device).copyWith(
            result: () => TranslationResult(
              engineId: device.id,
              engineName: device.name,
              text: 'Schönen Tag.',
            ),
          ),
        );
        return load;
      },
      skip: 1,
      expect: () => const <TranslateState>[],
    );

    blocTest<TranslateCubit, TranslateState>(
      'runs when an on-device translation finishes',
      setUp: () {
        stubUnsure();
        mocks.stubTranslate(resultBy(device));
      },
      build: () => mocks.build(),
      seed: () => readyState(
        engine: device,
        engines: engines,
        input: 'Good day. Bad dog.',
        source: en,
        target: de,
      ),
      act: (cubit) => cubit.translate(),
      wait: const Duration(milliseconds: 10),
      verify: (cubit) {
        expect(cubit.state.lowConfidenceSentences, unsure);
        verify(
          () => mocks.repository.lowConfidenceSentences(
            device,
            source: 'Good day. Bad dog.',
            translation: 'Guten Tag. Böser Hund.',
            sourceLanguage: en,
            targetLanguage: de,
          ),
        ).called(1);
      },
    );

    blocTest<TranslateCubit, TranslateState>(
      'does not run when another engine translated',
      setUp: () {
        stubUnsure();
        mocks.stubTranslate();
      },
      build: () => mocks.build(),
      seed: () => readyState(
        engines: engines,
        input: 'Good day. Bad dog.',
        source: en,
        target: de,
      ),
      act: (cubit) => cubit.translate(),
      wait: const Duration(milliseconds: 10),
      verify: (cubit) => verifyNever(
        () => mocks.repository.lowConfidenceSentences(
          any(),
          source: any(named: 'source'),
          translation: any(named: 'translation'),
          sourceLanguage: any(named: 'sourceLanguage'),
          targetLanguage: any(named: 'targetLanguage'),
        ),
      ),
    );
  });

  group('useOtherTranslation', () {
    final hello = readyState(
      input: 'hello',
      target: fr,
      result: const TranslationResult(
        engineId: 'mozhi:google',
        engineName: 'Google',
        text: 'bonjour',
        targetSynonyms: ['salut'],
      ),
      status: TranslateStatus.success,
    );

    blocTest<TranslateCubit, TranslateState>(
      'makes another translation the whole translation',
      build: () => mocks.build(),
      seed: () => hello,
      act: (cubit) => cubit.useOtherTranslation('salut'),
      verify: (cubit) {
        expect(cubit.state.output, 'salut');
        expect(cubit.state.status, TranslateStatus.success);
      },
    );

    blocTest<TranslateCubit, TranslateState>(
      'replaces the whole translation after a part was replaced',
      build: () => mocks.build(),
      seed: () => hello.copyWith(
        alternativesSpan: () => 'bon',
        alternativesSpanStart: () => 0,
      ),
      act: (cubit) => cubit.useOtherTranslation('salut'),
      verify: (cubit) {
        expect(cubit.state.output, 'salut');
        expect(cubit.state.alternativesSpan, isNull);
      },
    );
  });
}
