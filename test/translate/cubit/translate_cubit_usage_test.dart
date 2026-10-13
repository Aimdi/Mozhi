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
  late _MockUsageTracker tracker;

  setUp(() {
    mocks = TranslateMocks();
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

  /// (provider, input, output) of every recorded request, in order.
  List<(String, String, String)> recorded() {
    final captured = verify(
      () => tracker.recordText(
        captureAny(),
        input: captureAny(named: 'input'),
        output: captureAny(named: 'output'),
      ),
    ).captured;
    return [
      for (var i = 0; i < captured.length; i += 3)
        (
          captured[i] as String,
          captured[i + 1] as String,
          captured[i + 2] as String,
        ),
    ];
  }

  void verifyNothingRecorded() => verifyNever(
    () => tracker.recordText(
      any(),
      input: any(named: 'input'),
      output: any(named: 'output'),
    ),
  );

  /// "Hello world" -> German on Claude.
  TranslateState onClaude() =>
      readyState(engine: claude, input: 'Hello world', target: de);

  group('translations', () {
    blocTest<TranslateCubit, TranslateState>(
      'record a finished AI translation once, not per streamed chunk',
      setUp: () {
        when(() => mocks.repository.translate(any(), any())).thenAnswer(
          (_) => Stream.fromIterable([
            resultOf('Hal', engine: claude, isComplete: false),
            resultOf('Hallo', engine: claude, isComplete: false),
            resultOf('Hallo Welt', engine: claude),
          ]),
        );
      },
      build: () => mocks.build(),
      seed: onClaude,
      act: (cubit) => cubit.translate(),
      verify: (cubit) {
        expect(cubit.state.output, 'Hallo Welt');
        expect(recorded(), [('claude', 'Hello world', 'Hallo Welt')]);
      },
    );

    blocTest<TranslateCubit, TranslateState>(
      'are not recorded for engines without a provider',
      setUp: () => mocks.stubTranslate(),
      build: () => mocks.build(),
      seed: () => readyState(input: 'Hello world', target: de),
      act: (cubit) => cubit.translate(),
      verify: (cubit) {
        expect(cubit.state.status, TranslateStatus.success);
        verifyNothingRecorded();
      },
    );

    blocTest<TranslateCubit, TranslateState>(
      'are not recorded when they fail',
      setUp: () {
        when(() => mocks.repository.translate(any(), any())).thenAnswer(
          (_) => Stream.multi((controller) {
            controller
              ..add(resultOf('Hal', engine: claude, isComplete: false))
              ..addError(Exception('rate limited'));
            unawaited(controller.close());
          }),
        );
      },
      build: () => mocks.build(),
      seed: onClaude,
      act: (cubit) => cubit.translate(),
      verify: (cubit) {
        expect(cubit.state.status, TranslateStatus.failure);
        verifyNothingRecorded();
      },
    );

    test('are not recorded when cancelled before they finish', () async {
      final controller = StreamController<TranslationResult>();
      addTearDown(controller.close);
      when(() => mocks.repository.translate(any(), any()))
          .thenAnswer((_) => controller.stream);
      final cubit = mocks.build()..emit(onClaude());
      addTearDown(cubit.close);
      final done = cubit.translate();
      controller.add(resultOf('Hal', engine: claude, isComplete: false));
      await pumpEventQueue();
      cubit.clear();
      await done;
      verifyNothingRecorded();
    });

    blocTest<TranslateCubit, TranslateState>(
      'count both requests of a smart swap',
      setUp: () {
        when(() => mocks.repository.translate(any(), any()))
            .thenAnswer((invocation) {
              final request =
                  invocation.positionalArguments[1] as TranslationRequest;
              return Stream.value(
                resultOf(
                  '${request.text}->${request.target.code}',
                  engine: claude,
                  detected: 'de',
                ),
              );
            });
      },
      build: () => mocks.build(),
      seed: () => readyState(engine: claude, input: 'Hallo', target: de),
      act: (cubit) => cubit.translate(),
      verify: (cubit) {
        expect(cubit.state.target, en);
        expect(recorded(), [
          ('claude', 'Hallo', 'Hallo->de'),
          ('claude', 'Hallo', 'Hallo->en'),
        ]);
      },
    );

    blocTest<TranslateCubit, TranslateState>(
      'ignore tracker failures',
      setUp: () {
        when(
          () => tracker.recordText(
            any(),
            input: any(named: 'input'),
            output: any(named: 'output'),
          ),
        ).thenAnswer((_) async => throw StateError('storage full'));
        mocks.stubTranslate(resultOf('Hallo Welt', engine: claude));
      },
      build: () => mocks.build(),
      seed: onClaude,
      act: (cubit) => cubit.translate(),
      errors: () => <Object>[],
      verify: (cubit) {
        expect(cubit.state.status, TranslateStatus.success);
        expect(recorded(), hasLength(1));
      },
    );

    blocTest<TranslateCubit, TranslateState>(
      'ignore trackers that throw right away',
      setUp: () {
        when(
          () => tracker.recordText(
            any(),
            input: any(named: 'input'),
            output: any(named: 'output'),
          ),
        ).thenThrow(ArgumentError('invalid'));
        mocks.stubTranslate(resultOf('Hallo Welt', engine: claude));
      },
      build: () => mocks.build(),
      seed: onClaude,
      act: (cubit) => cubit.translate(),
      errors: () => <Object>[],
      verify: (cubit) {
        expect(cubit.state.status, TranslateStatus.success);
        expect(cubit.state.output, 'Hallo Welt');
      },
    );

    test('work without a tracker', () async {
      mocks
        ..usageTracker = null
        ..stubTranslate(resultOf('Hallo Welt', engine: claude));
      final cubit = mocks.build()..emit(onClaude());
      addTearDown(cubit.close);
      await cubit.translate();
      expect(cubit.state.output, 'Hallo Welt');
      verifyNothingRecorded();
    });
  });

  group('compare', () {
    blocTest<TranslateCubit, TranslateState>(
      'records each finished result of an engine with a provider',
      setUp: () {
        when(() => mocks.repository.compare(any(), any())).thenAnswer(
          (_) => Stream.fromIterable([
            CompareEntry.success(resultOf('Hallo')),
            CompareEntry.success(resultOf('Hallo!', engine: claude)),
            CompareEntry.failure(
              engineId: deepl.id,
              engineName: deepl.name,
              error: Exception('down'),
            ),
          ]),
        );
      },
      build: () => mocks.build(),
      seed: () => readyState(input: 'Hello'),
      act: (cubit) => cubit.runCompare(),
      verify: (_) => expect(recorded(), [('claude', 'Hello', 'Hallo!')]),
    );
  });

  group('AI extras', () {
    final hallo = resultOf('Hallo Welt', detected: 'en');

    TranslateState translated() => readyState(
      input: 'Hello world',
      target: de,
      result: hallo,
      status: TranslateStatus.success,
    );

    const input = 'Hello world\nHallo Welt';

    blocTest<TranslateCubit, TranslateState>(
      'alternatives are recorded on the assist engine',
      setUp: () {
        when(
          () => mocks.repository.getAlternatives(
            any(),
            any(),
            any(),
            span: any(named: 'span'),
          ),
        ).thenAnswer(
          (_) async => const AlternativeTranslations(
            description: 'Neutral.',
            alternatives: [Alternative(text: 'Hallo, Welt', explanation: ',')],
          ),
        );
      },
      build: () => mocks.build(),
      seed: translated,
      act: (cubit) => cubit.loadAlternatives(),
      verify: (_) =>
          expect(recorded(), [('claude', input, 'Neutral.\nHallo, Welt\n,')]),
    );

    blocTest<TranslateCubit, TranslateState>(
      'insights are recorded',
      setUp: () {
        when(
          () => mocks.repository.getInsights(any(), any(), any()),
        ).thenAnswer(
          (_) async => const [
            WordInsight(
              sourceText: 'world',
              targetText: 'Welt',
              explanation: 'Earth',
              variations: [Alternative(text: 'Erde', explanation: 'planet')],
            ),
          ],
        );
      },
      build: () => mocks.build(),
      seed: translated,
      act: (cubit) => cubit.loadInsights(),
      verify: (_) => expect(recorded(), [
        ('claude', input, 'world\nWelt\nnuance\nEarth\nErde\nplanet'),
      ]),
    );

    blocTest<TranslateCubit, TranslateState>(
      'suggestions are recorded',
      setUp: () {
        when(() => mocks.repository.getSuggestions(any(), any(), any()))
            .thenAnswer(
              (_) async => const [
                RefinementSuggestion(
                  label: 'Poetic',
                  instruction: 'Make it poetic.',
                  description: 'Lyrical',
                ),
              ],
            );
      },
      build: () => mocks.build(),
      seed: translated,
      act: (cubit) => cubit.loadSuggestions(),
      verify: (_) => expect(recorded(), [
        ('claude', input, 'Poetic\nMake it poetic.\nLyrical'),
      ]),
    );

    blocTest<TranslateCubit, TranslateState>(
      'a finished explanation is recorded once, with the question',
      setUp: () {
        when(
          () => mocks.repository.explain(
            any(),
            any(),
            any(),
            question: any(named: 'question'),
          ),
        ).thenAnswer((_) => Stream.fromIterable(['Because ', 'grammar.']));
      },
      build: () => mocks.build(),
      seed: translated,
      act: (cubit) => cubit.explain(question: 'Why?'),
      verify: (_) =>
          expect(recorded(), [('claude', '$input\nWhy?', 'Because grammar.')]),
    );

    blocTest<TranslateCubit, TranslateState>(
      'failed extras are not recorded',
      setUp: () {
        when(() => mocks.repository.getInsights(any(), any(), any()))
            .thenThrow(Exception('rate limited'));
        when(
          () => mocks.repository.explain(
            any(),
            any(),
            any(),
            question: any(named: 'question'),
          ),
        ).thenAnswer((_) => Stream.error(Exception('rate limited')));
      },
      build: () => mocks.build(),
      seed: translated,
      act: (cubit) async {
        await cubit.loadInsights();
        await cubit.explain();
      },
      verify: (_) => verifyNothingRecorded(),
    );

    blocTest<TranslateCubit, TranslateState>(
      'dictionary look-ups are recorded',
      setUp: () {
        when(
          () => mocks.repository.lookUp(
            any(),
            any(),
            source: any(named: 'source'),
            target: any(named: 'target'),
          ),
        ).thenAnswer(
          (_) async => const DictionaryEntry(
            word: 'Hello',
            pronunciation: 'həˈləʊ',
            partsOfSpeech: ['interjection'],
            senses: [
              DictionarySense(
                definition: 'a greeting',
                partOfSpeech: 'interjection',
                translations: ['Hallo'],
                usage: 'informal',
              ),
            ],
            examples: [
              DictionaryExample(source: 'Hello!', translation: 'Hallo!'),
            ],
            synonyms: ['hi'],
            etymology: 'Old English',
            notes: 'common',
          ),
        );
      },
      build: () => mocks.build(),
      seed: () => translated().copyWith(input: 'Hello'),
      act: (cubit) => cubit.lookUp(),
      verify: (_) => expect(recorded(), [
        (
          'claude',
          'Hello',
          'Hello\nhəˈləʊ\ninterjection\na greeting\ninterjection\nHallo\n'
              'informal\nHello!\nHallo!\nhi\nOld English\ncommon',
        ),
      ]),
    );
  });
}
