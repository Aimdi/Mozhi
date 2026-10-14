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

/// Input long enough (more than three words) for the smart swap to stop a
/// streaming translation at the first snapshot.
const _longText = 'how are you doing today';

void main() {
  setUpAll(registerTranslateFallbacks);

  late TranslateMocks mocks;

  setUp(() {
    mocks = TranslateMocks();
  });

  group('detection uncertainty', () {
    final uncertain = resultOf('Gift', detected: 'en').copyWith(
      detectionUncertain: true,
      detectedAlternatives: ['de', 'xx', 'nl'],
    );

    TranslateState shown({Language source = Language.auto}) => readyState(
      input: 'Gift',
      source: source,
      target: fr,
      result: uncertain,
      status: TranslateStatus.success,
    );

    test('is exposed for an auto source', () {
      final state = shown();
      expect(state.detectionUncertain, isTrue);
      expect(state.detectedAlternatives, ['de', 'xx', 'nl']);
      // Only languages the engine lists.
      expect(state.detectedAlternativeLanguages, [de]);
    });

    test('is not exposed for a selected source or a certain result', () {
      expect(shown(source: en).detectionUncertain, isFalse);
      expect(shown(source: en).detectedAlternatives, isEmpty);
      expect(
        shown().copyWith(result: () => resultOf('Gift')).detectionUncertain,
        isFalse,
      );
      expect(readyState().detectedAlternativeLanguages, isEmpty);
    });

    blocTest<TranslateCubit, TranslateState>(
      'useDetectedAlternative pins the source and translates again',
      setUp: () => mocks.stubTranslate(),
      build: () => mocks.build(),
      seed: shown,
      act: (cubit) => cubit.useDetectedAlternative('DE'),
      verify: (cubit) {
        expect(cubit.state.source, de);
        expect(cubit.state.output, 'Gift->fr');
        expect(cubit.state.detectionUncertain, isFalse);
        verify(() => mocks.settings.setLanguages(source: de)).called(1);
        expect(mocks.translateRequests().single.source, de);
      },
    );

    blocTest<TranslateCubit, TranslateState>(
      'useDetectedAlternative of the target language switches the target too',
      setUp: () => mocks.stubTranslate(),
      build: () => mocks.build(),
      seed: () => shown().copyWith(target: de),
      act: (cubit) => cubit.useDetectedAlternative('de'),
      verify: (cubit) {
        // Never German into German: English (for non-English text) instead.
        expect(cubit.state.source, de);
        expect(cubit.state.target, en);
        expect(cubit.state.output, 'Gift->en');
        final request = mocks.translateRequests().single;
        expect((request.source, request.target), (de, en));
        verify(() => mocks.settings.setLanguages(source: de)).called(1);
        verify(() => mocks.settings.setLanguages(target: en)).called(1);
        verify(() => mocks.settings.addRecentLanguage(en)).called(1);
      },
    );

    blocTest<TranslateCubit, TranslateState>(
      'useDetectedAlternative of the target does nothing without another one',
      build: () => mocks.build(),
      seed: () => shown().copyWith(target: de, targetLanguages: const [de]),
      act: (cubit) => cubit.useDetectedAlternative('de'),
      expect: () => <TranslateState>[],
      verify: (_) {
        verifyNever(
          () => mocks.settings.setLanguages(source: any(named: 'source')),
        );
      },
    );

    blocTest<TranslateCubit, TranslateState>(
      'useDetectedAlternative after a smart swap goes back to the old target',
      setUp: () {
        mocks.stubSettings(const AppSettings(recentLanguages: [de, es]));
        var calls = 0;
        when(() => mocks.repository.translate(any(), any()))
            .thenAnswer((invocation) {
              final request =
                  invocation.positionalArguments[1] as TranslationRequest;
              final text = '${request.text}->${request.target.code}';
              return Stream.value(switch (calls++) {
                // French detected while translating into French: swap.
                0 => resultOf(text, detected: 'fr'),
                // Into German, the second detection doubts French.
                1 => resultOf(text, detected: 'fr').copyWith(
                  detectionUncertain: true,
                  detectedAlternatives: ['de'],
                ),
                _ => resultOf(text, detected: request.source.code),
              });
            });
      },
      build: () => mocks.build(),
      seed: () => readyState(input: 'Gift', target: fr),
      act: (cubit) async {
        await cubit.translate();
        expect(cubit.state.target, de);
        expect(cubit.state.detectedAlternativeLanguages, [de]);
        cubit.useDetectedAlternative('de');
        await Future<void>.delayed(Duration.zero);
      },
      verify: (cubit) {
        expect(cubit.state.source, de);
        // Back to French (not Spanish, the next recent language).
        expect(cubit.state.target, fr);
        expect(cubit.state.output, 'Gift->fr');
      },
    );

    blocTest<TranslateCubit, TranslateState>(
      'useDetectedAlternative ignores codes the engine does not list',
      build: () => mocks.build(),
      seed: shown,
      act: (cubit) => cubit
        ..useDetectedAlternative('xx')
        ..useDetectedAlternative('auto'),
      expect: () => <TranslateState>[],
    );
  });

  group('smart swap', () {
    void stubDetect(String code) {
      when(() => mocks.repository.translate(any(), any())).thenAnswer((
        invocation,
      ) {
        final request = invocation.positionalArguments[1] as TranslationRequest;
        return Stream.value(
          resultOf('${request.text}->${request.target.code}', detected: code),
        );
      });
    }

    blocTest<TranslateCubit, TranslateState>(
      'stops a streaming translation as soon as the target is detected',
      setUp: () {
        final first = StreamController<TranslationResult>();
        addTearDown(first.close);
        var calls = 0;
        when(() => mocks.repository.translate(any(), any()))
            .thenAnswer((invocation) {
              if (calls++ == 0) return first.stream;
              final request =
                  invocation.positionalArguments[1] as TranslationRequest;
              return Stream.value(
                resultOf('text->${request.target.code}', engine: claude),
              );
            });
        // The marker arrives before any text.
        first.onListen = () => first.add(
          resultOf('', engine: claude, detected: 'en', isComplete: false),
        );
      },
      build: () => mocks.build(),
      seed: () => readyState(engine: claude, input: _longText),
      act: (cubit) => cubit.translate(),
      verify: (cubit) {
        expect(cubit.state.target, es);
        expect(cubit.state.output, 'text->es');
        expect(mocks.translateRequests().map((r) => r.target), [en, es]);
        expect(
          cubit.state.smartSwapNotice,
          const SmartSwapNotice(id: 1, previousTarget: en, newTarget: es),
        );
        expect(mocks.historyEntries().single.target, es);
      },
    );

    test('does not count the stopped request as usage', () async {
      final tracker = _MockUsageTracker();
      when(
        () => tracker.recordText(
          any(),
          input: any(named: 'input'),
          output: any(named: 'output'),
        ),
      ).thenAnswer((_) async => const UsageStats(requests: 1));
      mocks.usageTracker = tracker;
      final first = StreamController<TranslationResult>();
      addTearDown(first.close);
      var calls = 0;
      when(() => mocks.repository.translate(any(), any())).thenAnswer((_) {
        if (calls++ == 0) return first.stream;
        return Stream.value(resultOf('hola', engine: claude));
      });
      first.onListen = () => first.add(
        resultOf('', engine: claude, detected: 'en', isComplete: false),
      );
      final cubit = mocks.build()
        ..emit(readyState(engine: claude, input: _longText));
      addTearDown(cubit.close);

      await cubit.translate();

      expect(first.hasListener, isFalse);
      verify(
        () => tracker.recordText('claude', input: _longText, output: 'hola'),
      ).called(1);
    });

    group('of short input', () {
      /// Streams a partial snapshot whose marker names the target, then
      /// [last] (once the test completes [release]).
      Completer<void> stubShort(TranslationResult last) {
        final release = Completer<void>();
        var calls = 0;
        when(() => mocks.repository.translate(any(), any()))
            .thenAnswer((invocation) async* {
              final request =
                  invocation.positionalArguments[1] as TranslationRequest;
              if (calls++ > 0) {
                yield resultOf(
                  '${request.text}->${request.target.code}',
                  engine: claude,
                );
                return;
              }
              yield resultOf(
                'Gift',
                engine: claude,
                detected: 'en',
                isComplete: false,
              );
              await release.future;
              yield last;
            });
        return release;
      }

      test('waits for the final result before swapping', () async {
        final release = stubShort(
          resultOf('Gift', engine: claude, detected: 'en'),
        );
        final cubit = mocks.build()
          ..emit(readyState(engine: claude, input: 'Gift'));
        addTearDown(cubit.close);

        final done = cubit.translate();
        await Future<void>.delayed(Duration.zero);
        // The snapshot is shown; no swap yet.
        expect(cubit.state.target, en);
        expect(cubit.state.output, 'Gift');
        expect(cubit.state.smartSwapNotice, isNull);

        release.complete();
        await done;
        expect(cubit.state.target, es);
        expect(cubit.state.output, 'Gift->es');
      });

      test('does not swap when the second detection is unsure', () async {
        final release = stubShort(
          resultOf(
            'Gift',
            engine: claude,
            detected: 'en',
          ).copyWith(detectionUncertain: true, detectedAlternatives: ['de']),
        );
        final cubit = mocks.build()
          ..emit(readyState(engine: claude, input: 'Gift'));
        addTearDown(cubit.close);

        final done = cubit.translate();
        release.complete();
        await done;
        expect(cubit.state.target, en);
        expect(cubit.state.smartSwapNotice, isNull);
        expect(cubit.state.detectionUncertain, isTrue);
        // The other likely language is offered instead.
        expect(cubit.state.detectedAlternativeLanguages, [de]);
        expect(mocks.translateRequests(), hasLength(1));
      });
    });

    blocTest<TranslateCubit, TranslateState>(
      'never swaps on an uncertain detection',
      setUp: () =>
          when(() => mocks.repository.translate(any(), any())).thenAnswer(
            (_) => Stream.value(
              resultOf('Gift', detected: 'en').copyWith(
                detectionUncertain: true,
                detectedAlternatives: ['de'],
              ),
            ),
          ),
      build: () => mocks.build(),
      seed: () => readyState(input: 'Gift'),
      act: (cubit) => cubit.translate(),
      verify: (cubit) {
        expect(cubit.state.target, en);
        expect(cubit.state.smartSwapNotice, isNull);
        expect(cubit.state.output, 'Gift');
      },
    );

    blocTest<TranslateCubit, TranslateState>(
      'keeps streaming snapshots in another language',
      setUp: () {
        when(() => mocks.repository.translate(any(), any())).thenAnswer(
          (_) => Stream.fromIterable([
            resultOf('Hal', engine: claude, detected: 'de', isComplete: false),
            resultOf('Hallo', engine: claude, detected: 'de'),
          ]),
        );
      },
      build: () => mocks.build(),
      seed: () => readyState(engine: claude, input: 'hello'),
      act: (cubit) => cubit.translate(),
      verify: (cubit) {
        expect(cubit.state.target, en);
        expect(cubit.state.output, 'Hallo');
        expect(cubit.state.smartSwapNotice, isNull);
      },
    );

    blocTest<TranslateCubit, TranslateState>(
      'tells the UI once',
      setUp: () => stubDetect('en'),
      build: () => mocks.build(),
      seed: () => readyState(input: 'hello'),
      act: (cubit) async {
        await cubit.translate();
        expect(cubit.state.smartSwapNotice?.previousTarget, en);
        cubit
          ..consumeSmartSwapNotice()
          ..consumeSmartSwapNotice();
      },
      verify: (cubit) {
        expect(cubit.state.smartSwapNotice, isNull);
        expect(cubit.state.target, es);
      },
    );

    blocTest<TranslateCubit, TranslateState>(
      'notices of later swaps have new ids',
      setUp: () => stubDetect('en'),
      build: () => mocks.build(),
      seed: () => readyState(input: 'hello'),
      act: (cubit) async {
        await cubit.translate();
        cubit.emit(cubit.state.copyWith(target: en));
        await cubit.translate();
      },
      verify: (cubit) => expect(cubit.state.smartSwapNotice?.id, 2),
    );

    blocTest<TranslateCubit, TranslateState>(
      'undoSmartSwap restores the target and translates without a swap',
      setUp: () => stubDetect('en'),
      build: () => mocks.build(),
      seed: () => readyState(input: 'hello'),
      act: (cubit) async {
        await cubit.translate();
        cubit.consumeSmartSwapNotice();
        await cubit.undoSmartSwap();
        // The restored target is not swapped away from again.
        await cubit.translate();
      },
      verify: (cubit) {
        expect(cubit.state.target, en);
        expect(cubit.state.output, 'hello->en');
        expect(cubit.state.smartSwapNotice, isNull);
        expect(mocks.translateRequests().map((r) => r.target), [
          en,
          es,
          en,
          en,
        ]);
        verify(() => mocks.settings.setLanguages(target: en)).called(1);
        // Undoing twice does nothing.
        expect(cubit.undoSmartSwap(), completes);
      },
    );

    blocTest<TranslateCubit, TranslateState>(
      'undoSmartSwap clears an unconsumed notice',
      setUp: () => stubDetect('en'),
      build: () => mocks.build(),
      seed: () => readyState(input: 'hello'),
      act: (cubit) async {
        await cubit.translate();
        await cubit.undoSmartSwap();
      },
      verify: (cubit) => expect(cubit.state.smartSwapNotice, isNull),
    );

    blocTest<TranslateCubit, TranslateState>(
      'undoSmartSwap does nothing once the target changed',
      setUp: () => stubDetect('en'),
      build: () => mocks.build(),
      seed: () => readyState(input: 'hello'),
      act: (cubit) async {
        await cubit.translate();
        cubit.setTarget(fr);
        await cubit.undoSmartSwap();
      },
      verify: (cubit) => expect(cubit.state.target, fr),
    );

    blocTest<TranslateCubit, TranslateState>(
      'undoSmartSwap without a swap does nothing',
      build: () => mocks.build(),
      seed: () => readyState(input: 'hello'),
      act: (cubit) => cubit.undoSmartSwap(),
      expect: () => <TranslateState>[],
    );

    blocTest<TranslateCubit, TranslateState>(
      'undoSmartSwap compares again in compare mode',
      setUp: () {
        stubDetect('en');
        when(() => mocks.repository.compare(any(), any()))
            .thenAnswer((_) => const Stream.empty());
      },
      build: () => mocks.build(),
      seed: () => readyState(input: 'hello'),
      act: (cubit) async {
        await cubit.translate();
        cubit.setCompareMode(enabled: true);
        await cubit.undoSmartSwap();
      },
      verify: (cubit) {
        expect(cubit.state.target, en);
        final request =
            verify(() => mocks.repository.compare(any(), captureAny()))
                    .captured
                    .single
                as TranslationRequest;
        expect(request.target, en);
      },
    );

    blocTest<TranslateCubit, TranslateState>(
      'undoSmartSwap with an emptied input only restores the target',
      setUp: () => stubDetect('en'),
      build: () => mocks.build(),
      seed: () => readyState(input: 'hello'),
      act: (cubit) async {
        await cubit.translate();
        cubit.clear();
        await cubit.undoSmartSwap();
      },
      verify: (cubit) {
        expect(cubit.state.target, en);
        verify(() => mocks.repository.translate(any(), any())).called(2);
      },
    );
  });
}
