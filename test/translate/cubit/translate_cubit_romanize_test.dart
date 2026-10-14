import 'dart:async';

import 'package:bloc_test/bloc_test.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:mocktail/mocktail.dart';
import 'package:mozhi/settings/models/app_settings.dart';
import 'package:mozhi/translate/cubit/translate_cubit.dart';
import 'package:mozhi/usage/usage.dart';
import 'package:translation_repository/translation_repository.dart';

import 'translate_cubit_helpers.dart';

class _MockUsageTracker extends Mock implements UsageTracker;

void main() {
  setUpAll(registerTranslateFallbacks);

  late TranslateMocks mocks;

  setUp(() {
    mocks = TranslateMocks();
  });

  final konnichiwa = resultOf('こんにちは', detected: 'en');

  /// "Hello" (auto, detected English) translated to Japanese by Google.
  TranslateState japanese({TranslationResult? result}) => readyState(
    input: 'Hello',
    target: ja,
    result: result ?? konnichiwa,
    status: TranslateStatus.success,
  );

  TranslationResult transliterated(String text, String transliteration) =>
      TranslationResult(
        engineId: google.id,
        engineName: google.name,
        text: text,
        detectedSource: 'en',
        targetTransliteration: transliteration,
      );

  void stubRomanize(String text) {
    when(
      () => mocks.repository.romanize(
        any(),
        text: any(named: 'text'),
        language: any(named: 'language'),
      ),
    ).thenAnswer((_) async => text);
  }

  void verifyNoRomanize() => verifyNever(
    () => mocks.repository.romanize(
      any(),
      text: any(named: 'text'),
      language: any(named: 'language'),
    ),
  );

  group('loadRomanization', () {
    blocTest<TranslateCubit, TranslateState>(
      "uses the result's own transliteration without a request",
      build: () => mocks.build(),
      seed: () => japanese(result: transliterated('こんにちは', ' konnichiwa ')),
      act: (cubit) => cubit.loadRomanization(),
      expect: () => [
        japanese(result: transliterated('こんにちは', ' konnichiwa ')).copyWith(
          romanizationStatus: ExtraStatus.ready,
          romanization: () => 'konnichiwa',
        ),
      ],
      verify: (_) => verifyNoRomanize(),
    );

    blocTest<TranslateCubit, TranslateState>(
      'asks the extras engine for output in a non-Latin script',
      setUp: () => stubRomanize('konnichiwa'),
      build: () => mocks.build(),
      seed: japanese,
      act: (cubit) => cubit.loadRomanization(),
      expect: () => [
        japanese().copyWith(romanizationStatus: ExtraStatus.loading),
        japanese().copyWith(
          romanizationStatus: ExtraStatus.ready,
          romanization: () => 'konnichiwa',
        ),
      ],
      verify: (_) {
        verify(
          () => mocks.repository.romanize(claude, text: 'こんにちは', language: ja),
        ).called(1);
      },
    );

    blocTest<TranslateCubit, TranslateState>(
      'romanizes non-Latin letters in a Latin-script language',
      setUp: () => stubRomanize('Tokyo (Tōkyō)'),
      build: () => mocks.build(),
      seed: () => japanese(result: resultOf('Tokyo (東京)')).copyWith(target: en),
      act: (cubit) => cubit.loadRomanization(),
      verify: (cubit) => expect(cubit.state.romanization, 'Tokyo (Tōkyō)'),
    );

    blocTest<TranslateCubit, TranslateState>(
      'does nothing for Latin text in a Latin-script language',
      build: () => mocks.build(),
      seed: () => japanese(result: resultOf('Hallo')).copyWith(target: de),
      act: (cubit) => cubit.loadRomanization(),
      expect: () => <TranslateState>[],
      verify: (cubit) {
        verifyNoRomanize();
        expect(cubit.state.canRomanize, isFalse);
      },
    );

    blocTest<TranslateCubit, TranslateState>(
      'needs a finished, current output and an AI extras engine',
      build: () => mocks.build(),
      act: (cubit) async {
        for (final state in [
          japanese().copyWith(result: () => null),
          japanese(result: resultOf('こん', isComplete: false)),
          japanese().copyWith(input: 'Hello!'),
          japanese().copyWith(status: TranslateStatus.translating),
          japanese().copyWith(assistEngine: () => null),
          japanese().copyWith(assistEngine: () => gemma),
        ]) {
          cubit.emit(state);
          expect(cubit.state.canRomanize, isFalse, reason: '$state');
          await cubit.loadRomanization();
        }
      },
      skip: 6,
      expect: () => <TranslateState>[],
      verify: (_) => verifyNoRomanize(),
    );

    final failure = Exception('offline');

    blocTest<TranslateCubit, TranslateState>(
      'reports failures in the state',
      setUp: () {
        when(
          () => mocks.repository.romanize(
            any(),
            text: any(named: 'text'),
            language: any(named: 'language'),
          ),
        ).thenThrow(failure);
      },
      build: () => mocks.build(),
      seed: japanese,
      act: (cubit) => cubit.loadRomanization(),
      expect: () => [
        japanese().copyWith(romanizationStatus: ExtraStatus.loading),
        japanese().copyWith(
          romanizationStatus: ExtraStatus.failure,
          romanizationError: () => failure,
        ),
      ],
    );

    blocTest<TranslateCubit, TranslateState>(
      'can be retried after a failure, not reloaded while loading or loaded',
      setUp: () {
        var calls = 0;
        when(
          () => mocks.repository.romanize(
            any(),
            text: any(named: 'text'),
            language: any(named: 'language'),
          ),
        ).thenAnswer((_) async {
          if (calls++ == 0) throw failure;
          return 'konnichiwa';
        });
      },
      build: () => mocks.build(),
      seed: japanese,
      act: (cubit) async {
        await cubit.loadRomanization();
        final loading = cubit.loadRomanization();
        await cubit.loadRomanization();
        await loading;
        await cubit.loadRomanization();
      },
      verify: (cubit) {
        expect(cubit.state.romanization, 'konnichiwa');
        expect(cubit.state.romanizationError, isNull);
        verify(
          () => mocks.repository.romanize(
            any(),
            text: any(named: 'text'),
            language: any(named: 'language'),
          ),
        ).called(2);
      },
    );

    blocTest<TranslateCubit, TranslateState>(
      'drops answers for an output that changed meanwhile',
      setUp: () {
        when(
          () => mocks.repository.romanize(
            any(),
            text: any(named: 'text'),
            language: any(named: 'language'),
          ),
        ).thenAnswer((_) async {
          await Future<void>.delayed(const Duration(milliseconds: 10));
          return 'konnichiwa';
        });
      },
      build: () => mocks.build(),
      seed: japanese,
      act: (cubit) async {
        final done = cubit.loadRomanization();
        cubit.useAlternative('やあ');
        await done;
      },
      verify: (cubit) {
        expect(cubit.state.output, 'やあ');
        expect(cubit.state.romanization, isNull);
        expect(cubit.state.romanizationStatus, ExtraStatus.idle);
      },
    );

    blocTest<TranslateCubit, TranslateState>(
      'drops failures for an output that changed meanwhile',
      setUp: () {
        when(
          () => mocks.repository.romanize(
            any(),
            text: any(named: 'text'),
            language: any(named: 'language'),
          ),
        ).thenAnswer((_) async {
          await Future<void>.delayed(const Duration(milliseconds: 10));
          throw failure;
        });
      },
      build: () => mocks.build(),
      seed: japanese,
      act: (cubit) async {
        final done = cubit.loadRomanization();
        cubit.setInput('Hi');
        await done;
      },
      verify: (cubit) {
        expect(cubit.state.romanizationError, isNull);
        expect(cubit.state.romanizationStatus, ExtraStatus.idle);
      },
    );

    group('usage', () {
      late _MockUsageTracker tracker;

      setUp(() {
        tracker = _MockUsageTracker();
        when(
          () => tracker.recordText(
            any(),
            input: any(named: 'input'),
            output: any(named: 'output'),
          ),
        ).thenAnswer((_) async => const UsageStats(requests: 1));
        mocks.usageTracker = tracker;
      });

      blocTest<TranslateCubit, TranslateState>(
        'counts a romanization request',
        setUp: () => stubRomanize('konnichiwa'),
        build: () => mocks.build(),
        seed: japanese,
        act: (cubit) => cubit.loadRomanization(),
        verify: (_) {
          verify(
            () => tracker.recordText(
              'claude',
              input: 'こんにちは',
              output: 'konnichiwa',
            ),
          ).called(1);
        },
      );

      blocTest<TranslateCubit, TranslateState>(
        'does not count Latin text (answered without a request)',
        setUp: () => stubRomanize('OK'),
        build: () => mocks.build(),
        seed: () => japanese(result: resultOf('OK')),
        act: (cubit) => cubit.loadRomanization(),
        verify: (cubit) {
          expect(cubit.state.romanization, 'OK');
          verifyNever(
            () => tracker.recordText(
              any(),
              input: any(named: 'input'),
              output: any(named: 'output'),
            ),
          );
        },
      );
    });
  });

  group('automatic romanization', () {
    void stubJapanese(TranslationEngine engine) {
      when(() => mocks.repository.translate(any(), any()))
          .thenAnswer((_) => Stream.value(resultOf('こんにちは', engine: engine)));
    }

    blocTest<TranslateCubit, TranslateState>(
      'runs after a translation when the extras engine is local',
      setUp: () {
        stubJapanese(local);
        stubRomanize('konnichiwa');
      },
      build: () => mocks.build(),
      seed: () => readyState(
        engine: local,
        assistEngine: local,
        input: 'Hello',
        target: ja,
      ),
      act: (cubit) async {
        await cubit.translate();
        await Future<void>.delayed(Duration.zero);
      },
      verify: (cubit) {
        expect(cubit.state.romanization, 'konnichiwa');
        verify(
          () => mocks.repository.romanize(local, text: 'こんにちは', language: ja),
        ).called(1);
      },
    );

    blocTest<TranslateCubit, TranslateState>(
      'is not requested from cloud engines',
      setUp: () => stubJapanese(claude),
      build: () => mocks.build(),
      seed: () => readyState(engine: claude, input: 'Hello', target: ja),
      act: (cubit) => cubit.translate(),
      verify: (cubit) {
        expect(cubit.state.romanization, isNull);
        expect(cubit.state.canRomanize, isTrue);
        verifyNoRomanize();
      },
    );

    blocTest<TranslateCubit, TranslateState>(
      'is off while transliterations are hidden',
      setUp: () {
        stubJapanese(local);
        mocks.stubSettings(const AppSettings(showTransliteration: false));
      },
      build: () => mocks.build(),
      seed: () => readyState(
        engine: local,
        assistEngine: local,
        input: 'Hello',
        target: ja,
      ),
      act: (cubit) => cubit.translate(),
      verify: (_) => verifyNoRomanize(),
    );

    blocTest<TranslateCubit, TranslateState>(
      "uses Mozhi's transliteration on its own",
      setUp: () => mocks.stubTranslate(transliterated('こんにちは', 'konnichiwa')),
      build: () => mocks.build(),
      seed: () => readyState(input: 'Hello', target: ja),
      act: (cubit) => cubit.translate(),
      verify: (cubit) {
        expect(cubit.state.romanization, 'konnichiwa');
        verifyNoRomanize();
      },
    );

    blocTest<TranslateCubit, TranslateState>(
      'follows a picked compare result',
      build: () => mocks.build(),
      seed: () => readyState(input: 'Hello', target: ja),
      act: (cubit) => cubit.useCompareEntry(
        CompareEntry.success(transliterated('こんにちは', 'konnichiwa')),
      ),
      verify: (cubit) => expect(cubit.state.romanization, 'konnichiwa'),
    );
  });

  group('the romanization is reset', () {
    TranslateState romanized() =>
        japanese(result: transliterated('こんにちは', 'konnichiwa')).copyWith(
          romanizationStatus: ExtraStatus.ready,
          romanization: () => 'konnichiwa',
        );

    blocTest<TranslateCubit, TranslateState>(
      'by a new translation',
      setUp: () => mocks.stubTranslate(),
      build: () => mocks.build(),
      seed: romanized,
      act: (cubit) => cubit.translate(),
      verify: (cubit) {
        expect(cubit.state.output, 'Hello->ja');
        expect(cubit.state.romanization, isNull);
      },
    );

    blocTest<TranslateCubit, TranslateState>(
      'by an alternative, which also drops the old transliteration',
      build: () => mocks.build(),
      seed: romanized,
      act: (cubit) => cubit.useAlternative('やあ'),
      verify: (cubit) {
        expect(cubit.state.romanization, isNull);
        expect(cubit.state.result?.targetTransliteration, isEmpty);
        expect(cubit.state.result?.detectedSource, 'en');
      },
    );

    blocTest<TranslateCubit, TranslateState>(
      'by a variation',
      build: () => mocks.build(),
      seed: romanized,
      act: (cubit) => cubit.applyVariation(
        const WordInsight(sourceText: 'Hello', targetText: 'こんにちは'),
        'やあ',
      ),
      verify: (cubit) {
        expect(cubit.state.output, 'やあ');
        expect(cubit.state.romanization, isNull);
        expect(cubit.state.result?.targetTransliteration, isEmpty);
      },
    );
  });

  group('loadAlignment', () {
    final hallo = resultOf('Hallo Welt', detected: 'en');
    TranslateState translated() => readyState(
      input: 'Hello world',
      target: de,
      result: hallo,
      status: TranslateStatus.success,
    );

    const spans = [
      AlignedSpan(sourceStart: 0, sourceEnd: 5, targetStart: 0, targetEnd: 5),
      AlignedSpan(sourceStart: 6, sourceEnd: 11, targetStart: 6, targetEnd: 10),
    ];

    void stubAlign() {
      when(
        () => mocks.repository.align(
          any(),
          source: any(named: 'source'),
          translation: any(named: 'translation'),
          sourceLanguage: any(named: 'sourceLanguage'),
          targetLanguage: any(named: 'targetLanguage'),
        ),
      ).thenAnswer((_) async => spans);
    }

    void verifyNoAlign() => verifyNever(
      () => mocks.repository.align(
        any(),
        source: any(named: 'source'),
        translation: any(named: 'translation'),
        sourceLanguage: any(named: 'sourceLanguage'),
        targetLanguage: any(named: 'targetLanguage'),
      ),
    );

    blocTest<TranslateCubit, TranslateState>(
      'aligns the input and the output with the detected source',
      setUp: stubAlign,
      build: () => mocks.build(),
      seed: () => translated().copyWith(alignmentFocus: () => 0),
      act: (cubit) => cubit.loadAlignment(),
      expect: () => [
        translated().copyWith(alignmentStatus: ExtraStatus.loading),
        translated().copyWith(
          alignmentStatus: ExtraStatus.ready,
          alignment: spans,
        ),
      ],
      verify: (cubit) {
        verify(
          () => mocks.repository.align(
            claude,
            source: 'Hello world',
            translation: 'Hallo Welt',
            sourceLanguage: en,
            targetLanguage: de,
          ),
        ).called(1);
        expect(cubit.state.alignmentIndexAtSource(7), 1);
        expect(cubit.state.alignmentIndexAtTarget(2), 0);
        expect(cubit.state.alignmentIndexAtTarget(5), isNull);
        expect(cubit.state.alignmentIndexAtSource(5), isNull);
      },
    );

    final failure = Exception('bad json');

    blocTest<TranslateCubit, TranslateState>(
      'reports failures in the state',
      setUp: () {
        when(
          () => mocks.repository.align(
            any(),
            source: any(named: 'source'),
            translation: any(named: 'translation'),
            sourceLanguage: any(named: 'sourceLanguage'),
            targetLanguage: any(named: 'targetLanguage'),
          ),
        ).thenThrow(failure);
      },
      build: () => mocks.build(),
      seed: translated,
      act: (cubit) => cubit.loadAlignment(),
      expect: () => [
        translated().copyWith(alignmentStatus: ExtraStatus.loading),
        translated().copyWith(
          alignmentStatus: ExtraStatus.failure,
          alignmentError: () => failure,
        ),
      ],
    );

    blocTest<TranslateCubit, TranslateState>(
      'needs a finished, current output and an AI extras engine',
      build: () => mocks.build(),
      act: (cubit) async {
        for (final state in [
          translated().copyWith(result: () => null),
          translated().copyWith(input: 'Hello'),
          translated().copyWith(status: TranslateStatus.translating),
          translated().copyWith(assistEngine: () => null),
        ]) {
          cubit.emit(state);
          expect(cubit.state.canAlign, isFalse, reason: '$state');
          await cubit.loadAlignment();
        }
      },
      skip: 4,
      expect: () => <TranslateState>[],
      verify: (_) => verifyNoAlign(),
    );

    blocTest<TranslateCubit, TranslateState>(
      'is not requested again while loaded',
      setUp: stubAlign,
      build: () => mocks.build(),
      seed: translated,
      act: (cubit) async {
        await cubit.loadAlignment();
        await cubit.loadAlignment();
      },
      verify: (_) {
        verify(
          () => mocks.repository.align(
            any(),
            source: any(named: 'source'),
            translation: any(named: 'translation'),
            sourceLanguage: any(named: 'sourceLanguage'),
            targetLanguage: any(named: 'targetLanguage'),
          ),
        ).called(1);
      },
    );

    blocTest<TranslateCubit, TranslateState>(
      'is reset when the input changes, dropping a late answer',
      setUp: () {
        when(
          () => mocks.repository.align(
            any(),
            source: any(named: 'source'),
            translation: any(named: 'translation'),
            sourceLanguage: any(named: 'sourceLanguage'),
            targetLanguage: any(named: 'targetLanguage'),
          ),
        ).thenAnswer((_) async {
          await Future<void>.delayed(const Duration(milliseconds: 10));
          return spans;
        });
      },
      build: () => mocks.build(),
      seed: () => translated().copyWith(
        alignmentStatus: ExtraStatus.failure,
        alignmentError: () => failure,
      ),
      act: (cubit) async {
        final done = cubit.loadAlignment();
        cubit.setInput('Hello there');
        await done;
      },
      verify: (cubit) {
        expect(cubit.state.alignment, isEmpty);
        expect(cubit.state.alignmentStatus, ExtraStatus.idle);
        expect(cubit.state.alignmentError, isNull);
      },
    );

    blocTest<TranslateCubit, TranslateState>(
      'drops a late failure after the result changed',
      setUp: () {
        when(
          () => mocks.repository.align(
            any(),
            source: any(named: 'source'),
            translation: any(named: 'translation'),
            sourceLanguage: any(named: 'sourceLanguage'),
            targetLanguage: any(named: 'targetLanguage'),
          ),
        ).thenAnswer((_) async {
          await Future<void>.delayed(const Duration(milliseconds: 10));
          throw failure;
        });
      },
      build: () => mocks.build(),
      seed: translated,
      act: (cubit) async {
        final done = cubit.loadAlignment();
        cubit.useAlternative('Hallo, Welt');
        await done;
      },
      verify: (cubit) {
        expect(cubit.state.alignmentError, isNull);
        expect(cubit.state.alignmentStatus, ExtraStatus.idle);
      },
    );

    blocTest<TranslateCubit, TranslateState>(
      'counts the request as provider usage',
      setUp: () {
        stubAlign();
        final tracker = _MockUsageTracker();
        when(
          () => tracker.recordText(
            any(),
            input: any(named: 'input'),
            output: any(named: 'output'),
          ),
        ).thenAnswer((_) async => const UsageStats(requests: 1));
        mocks.usageTracker = tracker;
      },
      build: () => mocks.build(),
      seed: translated,
      act: (cubit) => cubit.loadAlignment(),
      verify: (_) {
        verify(
          () => mocks.usageTracker!.recordText(
            'claude',
            input: 'Hello world\nHallo Welt',
            output: 'Hello\nHallo\nworld\nWelt',
          ),
        ).called(1);
      },
    );

    group('focusAlignment', () {
      TranslateState aligned() => translated().copyWith(
        alignmentStatus: ExtraStatus.ready,
        alignment: spans,
      );

      blocTest<TranslateCubit, TranslateState>(
        'highlights a pair and clears the highlight',
        build: () => mocks.build(),
        seed: aligned,
        act: (cubit) {
          cubit.focusAlignment(1);
          expect(cubit.state.focusedAlignment, spans[1]);
          cubit
            ..focusAlignment(1)
            ..focusAlignment(null);
        },
        expect: () => [aligned().copyWith(alignmentFocus: () => 1), aligned()],
      );

      blocTest<TranslateCubit, TranslateState>(
        'ignores indices out of range',
        build: () => mocks.build(),
        seed: aligned,
        act: (cubit) => cubit
          ..focusAlignment(2)
          ..focusAlignment(-1),
        expect: () => <TranslateState>[],
        verify: (cubit) => expect(cubit.state.focusedAlignment, isNull),
      );
    });
  });
}
