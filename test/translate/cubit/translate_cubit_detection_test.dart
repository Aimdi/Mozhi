import 'dart:async';

import 'package:bloc_test/bloc_test.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:mocktail/mocktail.dart';
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
                resultOf('hello->${request.target.code}', engine: claude),
              );
            });
        // The marker arrives before any text.
        first.onListen = () => first.add(
          resultOf('', engine: claude, detected: 'en', isComplete: false),
        );
      },
      build: () => mocks.build(),
      seed: () => readyState(engine: claude, input: 'hello'),
      act: (cubit) => cubit.translate(),
      verify: (cubit) {
        expect(cubit.state.target, es);
        expect(cubit.state.output, 'hello->es');
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
        ..emit(readyState(engine: claude, input: 'hi'));
      addTearDown(cubit.close);

      await cubit.translate();

      expect(first.hasListener, isFalse);
      verify(() => tracker.recordText('claude', input: 'hi', output: 'hola'))
          .called(1);
    });

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
