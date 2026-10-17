import 'dart:async';

import 'package:bloc_test/bloc_test.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:mocktail/mocktail.dart';
import 'package:mozhi/settings/cubit/settings_cubit.dart';
import 'package:mozhi/settings/data/settings_repository.dart';
import 'package:mozhi/settings/models/app_settings.dart';
import 'package:mozhi/translate/cubit/translate_cubit.dart';
import 'package:mozhi/usage/usage.dart';
import 'package:translation_repository/translation_repository.dart';

import 'translate_cubit_helpers.dart';

class _MockUsageTracker extends Mock implements UsageTracker;

class _MockSettingsRepository extends Mock implements SettingsRepository;

void main() {
  setUpAll(registerTranslateFallbacks);

  late TranslateMocks mocks;

  setUp(() => mocks = TranslateMocks());

  /// "Hello" (not translated yet) -> German on [engine], French and Spanish
  /// as extra targets.
  TranslateState ready({
    TranslationEngine engine = google,
    List<Language> extraTargets = const [fr, es],
    Language source = Language.auto,
  }) => readyState(
    engine: engine,
    input: 'Hello',
    source: source,
    target: de,
  ).copyWith(extraTargets: extraTargets);

  /// [ready] with its main translation.
  TranslateState translated({
    TranslationEngine engine = google,
    List<Language> extraTargets = const [fr, es],
  }) => ready(engine: engine, extraTargets: extraTargets).copyWith(
    result: () => resultOf('Hello->de', engine: engine),
    resultInput: () => 'Hello',
    status: TranslateStatus.success,
  );

  /// A finished translation of "Hello" into [target] by [engine].
  ExtraTranslation done(
    Language target, {
    TranslationEngine engine = google,
    String text = 'Hello',
    Language source = Language.auto,
  }) => ExtraTranslation(
    target: target,
    status: TranslateStatus.success,
    result: resultOf('$text->${target.code}', engine: engine),
    request: TranslationRequest(text: text, source: source, target: target),
    engineId: engine.id,
  );

  /// Target codes of every translate request, in order.
  List<String> requestedTargets() => [
    for (final request in mocks.translateRequests()) request.target.code,
  ];

  /// Answers requests into [target] from [controller] (others as
  /// `TranslateMocks.stubTranslate`).
  void holdTarget(Language target, StreamController<TranslationResult> c) {
    when(() => mocks.repository.translate(any(), any())).thenAnswer((
      invocation,
    ) {
      final engine = invocation.positionalArguments[0] as TranslationEngine;
      final request = invocation.positionalArguments[1] as TranslationRequest;
      if (request.target == target) return c.stream;
      return Stream.value(
        resultOf('${request.text}->${request.target.code}', engine: engine),
      );
    });
  }

  group('setExtraTargets', () {
    blocTest<TranslateCubit, TranslateState>(
      'drops auto and duplicates and keeps at most four',
      build: () => mocks.build(),
      seed: () => ready(extraTargets: const []),
      act: (cubit) => cubit
        ..setExtraTargets(const [Language.auto, fr, fr, es, en, ja, de])
        ..setExtraTargets(const [fr, es, en, ja]),
      expect: () => [
        ready(extraTargets: const [fr, es, en, ja]),
      ],
      verify: (_) =>
          verifyNever(() => mocks.repository.translate(any(), any())),
    );

    blocTest<TranslateCubit, TranslateState>(
      'translates a new language right away when the input has a '
      'translation',
      setUp: () => mocks.stubTranslate(),
      build: () => mocks.build(),
      seed: () =>
          translated(extraTargets: const [es])
              .copyWith(extraTranslations: [done(es)]),
      act: (cubit) async {
        cubit.setExtraTargets(const [es, fr]);
        await Future<void>.delayed(Duration.zero);
      },
      verify: (cubit) {
        expect(requestedTargets(), ['fr']);
        expect(cubit.state.extraTranslationFor(fr)?.output, 'Hello->fr');
        expect(cubit.state.extraTranslationFor(es), done(es));
        verifyNever(() => mocks.history.add(any()));
      },
    );

    blocTest<TranslateCubit, TranslateState>(
      'translates a new language while the input is being translated',
      setUp: () => mocks.stubTranslate(),
      build: () => mocks.build(),
      seed: () =>
          ready(extraTargets: const [])
              .copyWith(status: TranslateStatus.translating),
      act: (cubit) async {
        cubit.setExtraTargets(const [fr]);
        await Future<void>.delayed(Duration.zero);
      },
      verify: (_) => expect(requestedTargets(), ['fr']),
    );

    blocTest<TranslateCubit, TranslateState>(
      'waits for Translate when the input has no current translation',
      build: () => mocks.build(),
      act: (cubit) async {
        for (final state in [
          ready(extraTargets: const []),
          translated(extraTargets: const []).copyWith(input: 'Hello there'),
          translated(extraTargets: const []).copyWith(compareMode: true),
          translated(extraTargets: const []).copyWith(engine: () => null),
        ]) {
          cubit
            ..emit(state)
            ..setExtraTargets(const [fr])
            ..setExtraTargets(const []);
        }
        await Future<void>.delayed(Duration.zero);
      },
      verify: (_) =>
          verifyNever(() => mocks.repository.translate(any(), any())),
    );

    blocTest<TranslateCubit, TranslateState>(
      'never sends a language in flight again when another one is added',
      build: () => mocks.build(),
      seed: () => ready(engine: claude, extraTargets: const [fr]),
      act: (cubit) async {
        final controller = StreamController<TranslationResult>();
        addTearDown(controller.close);
        holdTarget(fr, controller);
        final translation = cubit.translate();
        await Future<void>.delayed(Duration.zero);
        cubit
          ..setExtraTargets(const [fr, es])
          ..setExtraTargets(const [fr, es, en])
          ..setExtraTargets(const [fr, en]);
        await Future<void>.delayed(Duration.zero);
        expect(controller.hasListener, isTrue);
        controller.add(resultOf('Bonjour', engine: claude));
        await controller.close();
        await translation;
      },
      verify: (cubit) {
        expect(requestedTargets(), ['de', 'fr', 'es', 'en']);
        final french = cubit.state.extraTranslationFor(fr)!;
        expect(french.status, TranslateStatus.success);
        expect(french.output, 'Bonjour');
      },
    );

    blocTest<TranslateCubit, TranslateState>(
      'never retries a failed language when another one changes',
      setUp: () {
        when(() => mocks.repository.translate(any(), any()))
            .thenAnswer((invocation) {
              final request =
                  invocation.positionalArguments[1] as TranslationRequest;
              if (request.target == fr) {
                return Stream.error(Exception('rate limit'));
              }
              if (request.target == es) return const Stream.empty();
              return Stream.value(
                resultOf('${request.text}->${request.target.code}'),
              );
            });
      },
      build: () => mocks.build(),
      seed: () => ready(engine: claude, extraTargets: const [fr, es, en]),
      act: (cubit) async {
        await cubit.translate();
        expect(
          cubit.state.extraTranslationFor(fr)?.status,
          TranslateStatus.failure,
        );
        expect(
          cubit.state.extraTranslationFor(es)?.status,
          TranslateStatus.idle,
        );
        cubit
          ..setExtraTargets(const [fr, es])
          ..setExtraTargets(const [fr, es, en]);
        await Future<void>.delayed(Duration.zero);
      },
      verify: (cubit) {
        expect(requestedTargets(), ['de', 'fr', 'es', 'en', 'en']);
        expect(
          cubit.state.extraTranslationFor(fr)?.status,
          TranslateStatus.failure,
        );
      },
    );

    blocTest<TranslateCubit, TranslateState>(
      'cancels and drops the translation of a removed language',
      build: () => mocks.build(),
      seed: () => ready(extraTargets: const [fr]),
      act: (cubit) async {
        final controller = StreamController<TranslationResult>();
        holdTarget(fr, controller);
        unawaited(cubit.translate());
        await Future<void>.delayed(Duration.zero);
        expect(controller.hasListener, isTrue);
        expect(
          cubit.state.extraTranslationFor(fr)?.status,
          TranslateStatus.translating,
        );
        cubit.setExtraTargets(const []);
        expect(controller.hasListener, isFalse);
        expect(cubit.state.extraTranslations, isEmpty);
        await controller.close();
      },
    );
  });

  group('toggleExtraTarget', () {
    blocTest<TranslateCubit, TranslateState>(
      'adds and removes languages, at most four',
      build: () => mocks.build(),
      seed: () => ready(extraTargets: const []),
      act: (cubit) {
        cubit
          ..toggleExtraTarget(fr)
          ..toggleExtraTarget(es)
          ..toggleExtraTarget(en)
          ..toggleExtraTarget(ja)
          ..toggleExtraTarget(pirate);
        expect(cubit.state.extraTargets, const [fr, es, en, ja]);
        cubit.toggleExtraTarget(es);
        expect(cubit.state.extraTargets, const [fr, en, ja]);
      },
    );

    blocTest<TranslateCubit, TranslateState>(
      'removes a pick the engine lists as the language',
      build: () => mocks.build(),
      seed: () => ready(
        extraTargets: const [Language(code: 'fr-FR', name: 'French (France)')],
      ),
      act: (cubit) {
        expect(cubit.state.isExtraTarget(fr), isTrue);
        cubit.toggleExtraTarget(fr);
      },
      verify: (cubit) => expect(cubit.state.extraTargets, isEmpty),
    );
  });

  group('translations into extra targets', () {
    blocTest<TranslateCubit, TranslateState>(
      'run with the main translation, with the same engine and options, '
      'and only the main result is saved in history',
      setUp: () => mocks.stubTranslate(),
      build: () => mocks.build(),
      seed: () => ready().copyWith(
        options: const TranslationOptions(context: 'A greeting'),
      ),
      act: (cubit) => cubit.translate(),
      verify: (cubit) {
        final captured = verify(
          () => mocks.repository.translate(captureAny(), captureAny()),
        ).captured;
        expect(captured.whereType<TranslationEngine>(), [
          google,
          google,
          google,
        ]);
        final requests = captured.whereType<TranslationRequest>();
        expect([for (final r in requests) r.target], const [de, fr, es]);
        for (final request in requests) {
          expect(request.text, 'Hello');
          expect(request.source, Language.auto);
          expect(request.options.context, 'A greeting');
        }
        final state = cubit.state;
        expect(state.output, 'Hello->de');
        for (final target in const [fr, es]) {
          final translation = state.extraTranslationFor(target)!;
          expect(translation.status, TranslateStatus.success);
          expect(translation.output, 'Hello->${target.code}');
          expect(translation.resultInput, 'Hello');
          expect(translation.engineId, google.id);
          expect(translation.error, isNull);
        }
        final entries = mocks.historyEntries();
        expect(entries, hasLength(1));
        expect(entries.single.target, de);
      },
    );

    blocTest<TranslateCubit, TranslateState>(
      'stream partial results',
      setUp: () {
        when(() => mocks.repository.translate(any(), any()))
            .thenAnswer((invocation) {
              final request =
                  invocation.positionalArguments[1] as TranslationRequest;
              return Stream.fromIterable([
                resultOf('…', engine: claude, isComplete: false),
                resultOf('Hi ${request.target.code}', engine: claude),
              ]);
            });
      },
      build: () => mocks.build(),
      seed: () => ready(engine: claude, extraTargets: const [fr]),
      act: (cubit) => cubit.translate(),
      verify: (cubit) {
        expect(cubit.state.extraTranslationFor(fr)?.output, 'Hi fr');
      },
      expect: () => contains(
        isA<TranslateState>().having(
          (s) => s.extraTranslationFor(fr),
          'fr',
          isA<ExtraTranslation>()
              .having((t) => t.output, 'output', '…')
              .having((t) => t.status, 'status', TranslateStatus.translating),
        ),
      ),
    );

    blocTest<TranslateCubit, TranslateState>(
      'skip the main target, a chosen source and languages the engine lacks',
      setUp: () => mocks.stubTranslate(),
      build: () => mocks.build(),
      seed: () =>
          ready(source: en, extraTargets: const [de, en, ja, pirate, fr]),
      act: (cubit) => cubit.translate(),
      verify: (_) => expect(requestedTargets(), ['de', 'fr']),
    );

    blocTest<TranslateCubit, TranslateState>(
      'are not requested again while up to date',
      setUp: () => mocks.stubTranslate(),
      build: () => mocks.build(),
      seed: ready,
      act: (cubit) async {
        await cubit.translate();
        await cubit.translate();
      },
      verify: (_) => expect(requestedTargets(), ['de', 'fr', 'es', 'de']),
    );

    blocTest<TranslateCubit, TranslateState>(
      'in flight are waited for, not sent again, by another Translate',
      build: () => mocks.build(),
      seed: () => ready(engine: claude, extraTargets: const [fr]),
      act: (cubit) async {
        final controller = StreamController<TranslationResult>();
        addTearDown(controller.close);
        holdTarget(fr, controller);
        var done = false;
        unawaited(cubit.translate());
        await Future<void>.delayed(Duration.zero);
        unawaited(cubit.translate().then((_) => done = true));
        await Future<void>.delayed(Duration.zero);
        expect(done, isFalse);
        controller.add(resultOf('Bonjour', engine: claude));
        await controller.close();
        await Future<void>.delayed(Duration.zero);
        expect(done, isTrue);
      },
      verify: (_) => expect(requestedTargets(), ['de', 'fr', 'de']),
    );

    blocTest<TranslateCubit, TranslateState>(
      'retry a failed language with the next translation',
      setUp: () {
        var calls = 0;
        when(() => mocks.repository.translate(any(), any()))
            .thenAnswer((invocation) {
              final request =
                  invocation.positionalArguments[1] as TranslationRequest;
              if (request.target == fr && calls++ == 0) {
                return Stream.error(Exception('offline'));
              }
              return Stream.value(
                resultOf('${request.text}->${request.target.code}'),
              );
            });
      },
      build: () => mocks.build(),
      seed: () => ready(extraTargets: const [fr]),
      act: (cubit) async {
        await cubit.translate();
        await cubit.translate();
      },
      verify: (cubit) {
        expect(requestedTargets(), ['de', 'fr', 'de', 'fr']);
        expect(cubit.state.extraTranslationFor(fr)?.output, 'Hello->fr');
      },
    );

    group('in the language detected in the input', () {
      /// Answers every request with `<text>-><target>`, detecting [detect]
      /// of the text (English otherwise).
      void stubDetecting(Map<String, String> detect) {
        when(() => mocks.repository.translate(any(), any()))
            .thenAnswer((invocation) {
              final request =
                  invocation.positionalArguments[1] as TranslationRequest;
              return Stream.value(
                resultOf(
                  '${request.text}->${request.target.code}',
                  engine: claude,
                  detected: detect[request.text] ?? 'en',
                ),
              );
            });
      }

      blocTest<TranslateCubit, TranslateState>(
        'are dropped once detected and not requested again',
        setUp: () => stubDetecting(const {}),
        build: () => mocks.build(),
        seed: () => ready(engine: claude, extraTargets: const [en, fr]),
        act: (cubit) async {
          await cubit.translate();
          expect(cubit.state.activeExtraTargets, const [fr]);
          expect(cubit.state.extraTranslationFor(en), isNull);
          cubit.setInput('Hello there');
          await cubit.translate();
          // Adding it again while it is the input's language: no request.
          cubit
            ..setExtraTargets(const [fr])
            ..setExtraTargets(const [fr, en]);
          await Future<void>.delayed(Duration.zero);
        },
        verify: (cubit) {
          expect(requestedTargets(), ['de', 'en', 'fr', 'de', 'fr']);
          expect(cubit.state.extraTranslationFor(en), isNull);
          expect(
            cubit.state.extraTranslationFor(fr)?.output,
            'Hello there->fr',
          );
        },
      );

      blocTest<TranslateCubit, TranslateState>(
        'are cancelled when the detection arrives first',
        build: () => mocks.build(),
        seed: () => ready(engine: claude, extraTargets: const [en]),
        act: (cubit) async {
          final controller = StreamController<TranslationResult>();
          addTearDown(controller.close);
          when(() => mocks.repository.translate(any(), any()))
              .thenAnswer((invocation) {
                final request =
                    invocation.positionalArguments[1] as TranslationRequest;
                if (request.target == en) return controller.stream;
                return Stream.value(
                  resultOf('Hallo', engine: claude, detected: 'en'),
                );
              });
          await cubit.translate();
          expect(controller.hasListener, isFalse);
          expect(cubit.state.extraTranslations, isEmpty);
        },
      );

      blocTest<TranslateCubit, TranslateState>(
        'are translated once the input turns out to be in another language',
        setUp: () => stubDetecting(const {'Bonjour': 'fr'}),
        build: () => mocks.build(),
        seed: () => ready(engine: claude, extraTargets: const [en, fr]),
        act: (cubit) async {
          await cubit.translate();
          cubit.setInput('Bonjour');
          await cubit.translate();
        },
        verify: (cubit) {
          // French was asked for before the detection said it is the
          // input's language; English follows the new detection.
          expect(requestedTargets(), ['de', 'en', 'fr', 'de', 'fr', 'en']);
          expect(cubit.state.activeExtraTargets, const [en]);
          expect(cubit.state.extraTranslationFor(en)?.output, 'Bonjour->en');
          expect(cubit.state.extraTranslationFor(fr), isNull);
        },
      );

      blocTest<TranslateCubit, TranslateState>(
        'are not translated after a failed main translation',
        build: () => mocks.build(),
        seed: () => ready(engine: claude, extraTargets: const [en, fr]),
        act: (cubit) async {
          stubDetecting(const {});
          await cubit.translate();
          when(() => mocks.repository.translate(any(), any())).thenAnswer((
            invocation,
          ) {
            final request =
                invocation.positionalArguments[1] as TranslationRequest;
            if (request.target == de) return Stream.error(Exception('x'));
            return Stream.value(resultOf('Bonjour->${request.target.code}'));
          });
          cubit.setInput('Bonjour');
          await cubit.translate();
        },
        verify: (_) =>
            expect(requestedTargets(), ['de', 'en', 'fr', 'de', 'fr']),
      );
    });

    blocTest<TranslateCubit, TranslateState>(
      'are requested again when the source changes',
      setUp: () => mocks.stubTranslate(),
      build: () => mocks.build(),
      seed: ready,
      act: (cubit) async {
        await cubit.translate();
        cubit.setSource(en);
        await Future<void>.delayed(Duration.zero);
      },
      verify: (cubit) {
        expect(requestedTargets(), ['de', 'fr', 'es', 'de', 'fr', 'es']);
        expect(cubit.state.extraTranslationFor(fr)?.request?.source, en);
      },
    );

    blocTest<TranslateCubit, TranslateState>(
      'drop a language that becomes the main target',
      setUp: () => mocks.stubTranslate(),
      build: () => mocks.build(),
      seed: ready,
      act: (cubit) async {
        await cubit.translate();
        cubit.setTarget(es);
        await Future<void>.delayed(Duration.zero);
      },
      verify: (cubit) {
        expect(requestedTargets(), ['de', 'fr', 'es', 'es']);
        expect(cubit.state.activeExtraTargets, const [fr]);
        expect(cubit.state.extraTranslationFor(es), isNull);
        expect(cubit.state.extraTargets, const [fr, es]);
      },
    );

    blocTest<TranslateCubit, TranslateState>(
      'follow instant translation where it is free',
      setUp: () => mocks.stubTranslate(),
      build: () => mocks.build(),
      seed: () => ready().copyWith(input: ''),
      act: (cubit) async {
        cubit.setInput('Hello');
        await Future<void>.delayed(afterDebounce);
      },
      verify: (cubit) {
        expect(requestedTargets(), ['de', 'fr', 'es']);
        expect(cubit.state.instantResult, isTrue);
      },
    );

    blocTest<TranslateCubit, TranslateState>(
      'never start on their own on AI engines without the opt-in',
      build: () => mocks.build(),
      seed: () => ready(engine: claude).copyWith(input: ''),
      act: (cubit) async {
        cubit.setInput('Hello');
        await Future<void>.delayed(afterDebounce);
      },
      verify: (_) =>
          verifyNever(() => mocks.repository.translate(any(), any())),
    );

    blocTest<TranslateCubit, TranslateState>(
      'follow instant translation on AI engines with the opt-in',
      setUp: () {
        mocks
          ..stubSettings(const AppSettings(instantTranslateAi: true))
          ..stubTranslate();
      },
      build: () => mocks.build(),
      seed: () => ready(engine: claude).copyWith(input: ''),
      act: (cubit) async {
        cubit.setInput('Hello');
        await Future<void>.delayed(afterDebounce);
      },
      verify: (_) => expect(requestedTargets(), ['de', 'fr', 'es']),
    );

    blocTest<TranslateCubit, TranslateState>(
      'never run in compare mode',
      setUp: () {
        when(() => mocks.repository.compare(any(), any()))
            .thenAnswer((_) => const Stream.empty());
      },
      build: () => mocks.build(),
      seed: () => ready().copyWith(compareMode: true),
      act: (cubit) => cubit.translate(),
      verify: (_) =>
          verifyNever(() => mocks.repository.translate(any(), any())),
    );

    blocTest<TranslateCubit, TranslateState>(
      'stay, out of date, when the input is edited',
      setUp: () {
        mocks
          ..stubSettings(const AppSettings(instantTranslate: false))
          ..stubTranslate();
      },
      build: () => mocks.build(),
      seed: ready,
      act: (cubit) async {
        await cubit.translate();
        cubit.setInput('Hello there');
      },
      verify: (cubit) {
        final french = cubit.state.extraTranslationFor(fr)!;
        expect(french.output, 'Hello->fr');
        expect(french.isStaleFor(cubit.state.input), isTrue);
        expect(french.isStaleFor('Hello'), isFalse);
      },
    );

    blocTest<TranslateCubit, TranslateState>(
      'of old text land out of date',
      setUp: () =>
          mocks.stubSettings(const AppSettings(instantTranslate: false)),
      build: () => mocks.build(),
      seed: () => ready(extraTargets: const [fr]),
      act: (cubit) async {
        final controller = StreamController<TranslationResult>();
        addTearDown(controller.close);
        holdTarget(fr, controller);
        unawaited(cubit.translate());
        await Future<void>.delayed(Duration.zero);
        cubit.setInput('Hello there');
        controller.add(resultOf('Bonjour'));
        await Future<void>.delayed(Duration.zero);
      },
      verify: (cubit) {
        final french = cubit.state.extraTranslationFor(fr)!;
        expect(french.output, 'Bonjour');
        expect(french.status, TranslateStatus.success);
        expect(french.isStaleFor(cubit.state.input), isTrue);
      },
    );

    blocTest<TranslateCubit, TranslateState>(
      'are cancelled and dropped when the input is cleared',
      build: () => mocks.build(),
      seed: () => ready(extraTargets: const [fr]),
      act: (cubit) async {
        final controller = StreamController<TranslationResult>();
        addTearDown(controller.close);
        holdTarget(fr, controller);
        unawaited(cubit.translate());
        await Future<void>.delayed(Duration.zero);
        cubit.clear();
        expect(controller.hasListener, isFalse);
        expect(cubit.state.extraTranslations, isEmpty);
        cubit
          ..setInput('Hi')
          ..setInput('');
        expect(cubit.state.extraTranslations, isEmpty);
      },
    );

    blocTest<TranslateCubit, TranslateState>(
      'are dropped and requested again with a new engine',
      setUp: () => mocks.stubTranslate(),
      build: () => mocks.build(),
      seed: () =>
          translated().copyWith(extraTranslations: [done(fr), done(es)]),
      act: (cubit) => cubit.selectEngine(deepl),
      verify: (cubit) {
        verify(() => mocks.repository.translate(deepl, any())).called(3);
        expect(cubit.state.extraTranslationFor(fr)?.engineId, deepl.id);
        expect(cubit.state.extraTranslationFor(fr)?.result?.engineId, deepl.id);
      },
    );

    blocTest<TranslateCubit, TranslateState>(
      'are not part of one-off refinements of the main output',
      setUp: () => mocks.stubTranslate(),
      build: () => mocks.build(),
      seed: () =>
          translated().copyWith(extraTranslations: [done(fr), done(es)]),
      act: (cubit) =>
          cubit.applySuggestion(RefinementSuggestion.defaults.first),
      verify: (_) => expect(requestedTargets(), ['de']),
    );

    final failure = Exception('offline');

    blocTest<TranslateCubit, TranslateState>(
      'report failures per language and can be retried',
      setUp: () {
        var calls = 0;
        when(() => mocks.repository.translate(any(), any()))
            .thenAnswer((invocation) {
              final request =
                  invocation.positionalArguments[1] as TranslationRequest;
              if (request.target == fr && calls++ == 0) {
                return Stream.error(failure);
              }
              return Stream.value(
                resultOf('${request.text}->${request.target.code}'),
              );
            });
      },
      build: () => mocks.build(),
      seed: ready,
      act: (cubit) async {
        await cubit.translate();
        final french = cubit.state.extraTranslationFor(fr)!;
        expect(french.status, TranslateStatus.failure);
        expect(french.error, failure);
        expect(french.result, isNull);
        expect(cubit.state.output, 'Hello->de');
        expect(
          cubit.state.extraTranslationFor(es)?.status,
          TranslateStatus.success,
        );
        await cubit.retryExtraTarget(fr);
      },
      verify: (cubit) {
        final french = cubit.state.extraTranslationFor(fr)!;
        expect(french.status, TranslateStatus.success);
        expect(french.output, 'Hello->fr');
        expect(french.error, isNull);
        expect(requestedTargets(), ['de', 'fr', 'es', 'fr']);
      },
    );

    blocTest<TranslateCubit, TranslateState>(
      'report a request that cannot start',
      setUp: () {
        when(() => mocks.repository.translate(any(), any()))
            .thenAnswer((invocation) {
              final request =
                  invocation.positionalArguments[1] as TranslationRequest;
              if (request.target == fr) throw failure;
              return Stream.value(resultOf('Hallo'));
            });
      },
      build: () => mocks.build(),
      seed: () => ready(extraTargets: const [fr]),
      act: (cubit) => cubit.translate(),
      verify: (cubit) {
        expect(
          cubit.state.extraTranslationFor(fr)?.status,
          TranslateStatus.failure,
        );
        expect(cubit.state.extraTranslationFor(fr)?.error, failure);
      },
    );

    blocTest<TranslateCubit, TranslateState>(
      'end idle when a stream closes without a result',
      setUp: () {
        when(() => mocks.repository.translate(any(), any()))
            .thenAnswer((invocation) {
              final request =
                  invocation.positionalArguments[1] as TranslationRequest;
              if (request.target == fr) return const Stream.empty();
              return Stream.value(resultOf('Hallo'));
            });
      },
      build: () => mocks.build(),
      seed: () => ready(extraTargets: const [fr]),
      act: (cubit) => cubit.translate(),
      verify: (cubit) => expect(
        cubit.state.extraTranslationFor(fr)?.status,
        TranslateStatus.idle,
      ),
    );

    blocTest<TranslateCubit, TranslateState>(
      'retry only active languages of non-empty input',
      build: () => mocks.build(),
      act: (cubit) async {
        cubit.emit(ready().copyWith(input: ' '));
        await cubit.retryExtraTarget(fr);
        cubit.emit(ready());
        await cubit.retryExtraTarget(ja);
        await cubit.retryExtraTarget(de);
        cubit.emit(ready().copyWith(engine: () => null));
        await cubit.retryExtraTarget(fr);
      },
      verify: (_) =>
          verifyNever(() => mocks.repository.translate(any(), any())),
    );

    blocTest<TranslateCubit, TranslateState>(
      'never translate twice after a smart swap into one of them',
      setUp: () {
        when(() => mocks.repository.translate(any(), any())).thenAnswer((
          invocation,
        ) {
          final request =
              invocation.positionalArguments[1] as TranslationRequest;
          return Stream.value(
            resultOf('${request.text}->${request.target.code}', detected: 'en'),
          );
        });
      },
      build: () => mocks.build(),
      // English into English: smart swap to Spanish.
      seed: () =>
          readyState(input: 'Hello').copyWith(extraTargets: const [es, fr]),
      act: (cubit) => cubit.translate(),
      verify: (cubit) {
        expect(cubit.state.target, es);
        expect(cubit.state.output, 'Hello->es');
        expect(cubit.state.extraTranslationFor(es), isNull);
        expect(cubit.state.extraTranslationFor(fr)?.output, 'Hello->fr');
        expect(requestedTargets(), ['en', 'es', 'fr', 'es']);
      },
    );

    test('are cancelled when the cubit closes', () async {
      final controller = StreamController<TranslationResult>();
      addTearDown(controller.close);
      holdTarget(fr, controller);
      final cubit = mocks.build()..emit(ready(extraTargets: const [fr]));
      final translation = cubit.translate();
      await Future<void>.delayed(Duration.zero);
      expect(controller.hasListener, isTrue);
      await cubit.close();
      expect(controller.hasListener, isFalse);
      await translation;
    });

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
        'counts each request, but not results from the cache',
        setUp: () {
          when(() => mocks.repository.translate(any(), any()))
              .thenAnswer((invocation) {
                final request =
                    invocation.positionalArguments[1] as TranslationRequest;
                return Stream.fromIterable([
                  resultOf('…', engine: claude, isComplete: false),
                  TranslationResult(
                    engineId: claude.id,
                    engineName: claude.name,
                    text: 'Hi ${request.target.code}',
                    fromCache: request.target == es,
                  ),
                ]);
              });
        },
        build: () => mocks.build(),
        seed: () => ready(engine: claude),
        act: (cubit) => cubit.translate(),
        verify: (_) {
          final captured = verify(
            () => tracker.recordText(
              'claude',
              input: 'Hello',
              output: captureAny(named: 'output'),
            ),
          ).captured;
          expect(captured, ['Hi de', 'Hi fr']);
        },
      );
    });
  });

  group('insertExtraTranslation', () {
    /// "Hello" from English into German on Claude (instant translation is
    /// off for AI), with a finished French translation.
    TranslateState withFrench({
      Language source = en,
      List<Language> sources = const [Language.auto, en, de, fr, es],
      bool complete = true,
    }) =>
        readyState(
          engine: claude,
          input: 'Hello',
          source: source,
          target: de,
          result: resultOf('Hallo', engine: claude),
          status: TranslateStatus.success,
        ).copyWith(
          sourceLanguages: sources,
          extraTargets: const [fr],
          extraTranslations: [
            ExtraTranslation(
              target: fr,
              status: complete
                  ? TranslateStatus.success
                  : TranslateStatus.translating,
              result: resultOf('Bonjour', engine: claude, isComplete: complete),
              request: const TranslationRequest(
                text: 'Hello',
                source: en,
                target: fr,
              ),
              engineId: claude.id,
            ),
          ],
        );

    blocTest<TranslateCubit, TranslateState>(
      'puts the translation into the input and makes its language the '
      'source, without translating it on its own',
      build: () => mocks.build(),
      seed: withFrench,
      act: (cubit) async {
        cubit.insertExtraTranslation(fr);
        await Future<void>.delayed(afterDebounce);
      },
      verify: (cubit) {
        expect(cubit.state.input, 'Bonjour');
        expect(cubit.state.source, fr);
        expect(cubit.state.isResultStale, isTrue);
        // French is the source now: not translated into French again.
        expect(cubit.state.activeExtraTargets, isEmpty);
        verify(() => mocks.settings.setLanguages(source: fr)).called(1);
        verifyNever(() => mocks.repository.translate(any(), any()));
      },
    );

    blocTest<TranslateCubit, TranslateState>(
      'detects the language when the engine does not list it as a source',
      build: () => mocks.build(),
      seed: () => withFrench(sources: const [Language.auto, en, de]),
      act: (cubit) => cubit.insertExtraTranslation(fr),
      verify: (cubit) {
        expect(cubit.state.input, 'Bonjour');
        expect(cubit.state.source, Language.auto);
      },
    );

    blocTest<TranslateCubit, TranslateState>(
      'keeps detecting an auto source',
      build: () => mocks.build(),
      seed: () => withFrench(source: Language.auto),
      act: (cubit) => cubit.insertExtraTranslation(fr),
      verify: (cubit) {
        expect(cubit.state.input, 'Bonjour');
        expect(cubit.state.source, Language.auto);
        verifyNever(
          () => mocks.settings.setLanguages(source: any(named: 'source')),
        );
      },
    );

    blocTest<TranslateCubit, TranslateState>(
      'needs a finished translation',
      build: () => mocks.build(),
      seed: () => withFrench(complete: false),
      act: (cubit) => cubit
        ..insertExtraTranslation(fr)
        ..insertExtraTranslation(es)
        ..undoInsertExtraTranslation(),
      expect: () => <TranslateState>[],
    );

    group('undoInsertExtraTranslation', () {
      blocTest<TranslateCubit, TranslateState>(
        'brings the input and the source back, with their translation',
        build: () => mocks.build(),
        seed: withFrench,
        act: (cubit) async {
          cubit
            ..insertExtraTranslation(fr)
            ..undoInsertExtraTranslation();
          await Future<void>.delayed(afterDebounce);
        },
        verify: (cubit) {
          final state = cubit.state;
          expect(state.input, 'Hello');
          expect(state.source, en);
          expect(state.output, 'Hallo');
          expect(state.isResultStale, isFalse);
          expect(state.activeExtraTargets, const [fr]);
          expect(state.extraTranslationFor(fr)?.output, 'Bonjour');
          verify(() => mocks.settings.setLanguages(source: fr)).called(1);
          verify(() => mocks.settings.setLanguages(source: en)).called(1);
          verifyNever(() => mocks.repository.translate(any(), any()));
        },
      );

      blocTest<TranslateCubit, TranslateState>(
        'translates the input again like typed text when its translation '
        'was replaced',
        setUp: () => mocks.stubTranslate(),
        build: () => mocks.build(),
        seed: () => withFrench().copyWith(engine: () => google),
        act: (cubit) async {
          cubit.insertExtraTranslation(fr);
          await Future<void>.delayed(afterDebounce);
          expect(cubit.state.output, 'Bonjour->de');
          cubit.undoInsertExtraTranslation();
          await Future<void>.delayed(afterDebounce);
        },
        verify: (cubit) {
          expect(cubit.state.input, 'Hello');
          expect(cubit.state.source, en);
          expect(cubit.state.output, 'Hello->de');
          final requests = mocks.translateRequests();
          expect(
            [for (final r in requests) (r.text, r.source.code, r.target.code)],
            [
              ('Bonjour', 'fr', 'de'),
              ('Hello', 'en', 'de'),
              ('Hello', 'en', 'fr'),
            ],
          );
        },
      );

      blocTest<TranslateCubit, TranslateState>(
        'keeps an auto source',
        build: () => mocks.build(),
        seed: () => withFrench(source: Language.auto),
        act: (cubit) => cubit
          ..insertExtraTranslation(fr)
          ..undoInsertExtraTranslation(),
        verify: (cubit) {
          expect(cubit.state.input, 'Hello');
          expect(cubit.state.source, Language.auto);
          verifyNever(
            () => mocks.settings.setLanguages(source: any(named: 'source')),
          );
        },
      );

      blocTest<TranslateCubit, TranslateState>(
        'does nothing once the input was edited, or twice',
        build: () => mocks.build(),
        seed: withFrench,
        act: (cubit) {
          cubit
            ..insertExtraTranslation(fr)
            ..setInput('Bonjour !')
            ..undoInsertExtraTranslation();
          expect(cubit.state.input, 'Bonjour !');
          cubit
            ..setInput('Bonjour')
            ..undoInsertExtraTranslation();
          expect(cubit.state.input, 'Bonjour');
          expect(cubit.state.source, fr);
        },
      );

      blocTest<TranslateCubit, TranslateState>(
        'does nothing when the insert changed nothing',
        build: () => mocks.build(),
        seed: () =>
            withFrench(source: Language.auto).copyWith(input: 'Bonjour'),
        act: (cubit) {
          cubit
            ..insertExtraTranslation(fr)
            ..undoInsertExtraTranslation();
          expect(cubit.state.input, 'Bonjour');
        },
      );
    });
  });

  group('saved in settings', () {
    /// The extra targets saved through `SettingsCubit.setExtraTargets`.
    List<List<Language>> saved() => [
      for (final call in verify(
        () => mocks.settings.setExtraTargets(captureAny()),
      ).captured)
        call as List<Language>,
    ];

    /// DeepL also offers Japanese.
    void deeplOffersJapanese() =>
        when(() => mocks.repository.getTargetLanguages(deepl))
            .thenAnswer((_) async => const [...targets, ja]);

    test('are the extra targets at start', () async {
      mocks.stubSettings(const AppSettings(extraTargets: [ja, fr, pirate]));
      final cubit = mocks.build();
      addTearDown(cubit.close);
      expect(cubit.state.extraTargets, const [ja, fr, pirate]);
    });

    test('are cleaned up at start', () async {
      mocks.stubSettings(
        const AppSettings(extraTargets: [Language.auto, fr, fr, es, en, de]),
      );
      final cubit = mocks.build();
      addTearDown(cubit.close);
      expect(cubit.state.extraTargets, const [fr, es, en, de]);
    });

    test('none are saved by default (older settings)', () async {
      final cubit = mocks.build();
      addTearDown(cubit.close);
      expect(cubit.state.extraTargets, isEmpty);
      await cubit.loadEngines();
      expect(cubit.state.extraTargets, isEmpty);
    });

    blocTest<TranslateCubit, TranslateState>(
      'are used once the engine offers them; the others stay picked',
      setUp: () {
        mocks.stubSettings(const AppSettings(extraTargets: [ja, fr, pirate]));
        deeplOffersJapanese();
      },
      build: () => mocks.build(),
      act: (cubit) async {
        await cubit.loadEngines();
        expect(cubit.state.engine, google);
        expect(cubit.state.activeExtraTargets, const [fr]);
        expect(cubit.state.unavailableExtraTargets, const [ja, pirate]);
        await cubit.selectEngine(deepl);
        expect(cubit.state.activeExtraTargets, const [ja, fr]);
        expect(cubit.state.unavailableExtraTargets, const [pirate]);
        await cubit.selectEngine(claude);
        expect(cubit.state.activeExtraTargets, const [fr, pirate]);
        expect(cubit.state.unavailableExtraTargets, const [ja]);
        await cubit.selectEngine(google);
      },
      verify: (cubit) {
        expect(cubit.state.extraTargets, const [ja, fr, pirate]);
        expect(cubit.state.activeExtraTargets, const [fr]);
        verifyNever(() => mocks.settings.setExtraTargets(any()));
      },
    );

    blocTest<TranslateCubit, TranslateState>(
      'keep languages set otherwise across engines',
      build: () => mocks.build(),
      seed: () => ready(extraTargets: const [fr, ja]),
      act: (cubit) async {
        deeplOffersJapanese();
        await cubit.selectEngine(deepl);
        expect(cubit.state.activeExtraTargets, const [fr, ja]);
        await cubit.selectEngine(google);
      },
      verify: (cubit) {
        expect(cubit.state.extraTargets, const [fr, ja]);
        expect(cubit.state.activeExtraTargets, const [fr]);
      },
    );

    blocTest<TranslateCubit, TranslateState>(
      'changes are saved',
      build: () => mocks.build(),
      seed: () => ready(extraTargets: const []),
      act: (cubit) => cubit
        ..toggleExtraTarget(fr)
        ..toggleExtraTarget(es)
        ..toggleExtraTarget(fr)
        ..setExtraTargets(const [es])
        ..setExtraTargets(const [Language.auto, de, de]),
      verify: (_) => expect(saved(), const [
        [fr],
        [fr, es],
        [es],
        [de],
      ]),
    );

    blocTest<TranslateCubit, TranslateState>(
      'changes are saved with the picks the engine does not offer',
      setUp: () =>
          mocks.stubSettings(const AppSettings(extraTargets: [ja, fr])),
      build: () => mocks.build(),
      act: (cubit) async {
        await cubit.loadEngines();
        cubit.toggleExtraTarget(es);
        expect(cubit.state.activeExtraTargets, const [fr, es]);
        expect(cubit.state.unavailableExtraTargets, const [ja]);
      },
      verify: (_) => expect(saved(), const [
        [ja, fr, es],
      ]),
    );

    blocTest<TranslateCubit, TranslateState>(
      'removing all also removes the picks the engine does not offer, so '
      'another engine does not translate into them',
      setUp: () {
        mocks
          ..stubSettings(const AppSettings(extraTargets: [ja, fr]))
          ..stubTranslate();
        deeplOffersJapanese();
      },
      build: () => mocks.build(),
      act: (cubit) async {
        await cubit.loadEngines();
        cubit
          ..setExtraTargets(const [])
          ..setInput('Hello');
        await cubit.selectEngine(deepl);
      },
      verify: (cubit) {
        expect(saved(), const [<Language>[]]);
        expect(cubit.state.extraTargets, isEmpty);
        expect(cubit.state.unavailableExtraTargets, isEmpty);
        expect(requestedTargets(), ['en']);
      },
    );

    blocTest<TranslateCubit, TranslateState>(
      'a pick the engine does not offer is removed by toggling it',
      setUp: () =>
          mocks.stubSettings(const AppSettings(extraTargets: [ja, fr, pirate])),
      build: () => mocks.build(),
      act: (cubit) async {
        await cubit.loadEngines();
        cubit
          ..toggleExtraTarget(pirate)
          ..toggleExtraTarget(ja);
      },
      verify: (cubit) {
        expect(cubit.state.extraTargets, const [fr]);
        expect(saved(), const [
          [ja, fr],
          [fr],
        ]);
      },
    );

    blocTest<TranslateCubit, TranslateState>(
      'picks the engine does not offer count towards the limit (none is '
      'dropped)',
      setUp: () => mocks.stubSettings(
        const AppSettings(extraTargets: [ja, pirate, fr, es]),
      ),
      build: () => mocks.build(),
      act: (cubit) async {
        await cubit.loadEngines();
        expect(cubit.state.activeExtraTargets, const [fr, es]);
        cubit.toggleExtraTarget(de);
        expect(cubit.state.extraTargets, const [ja, pirate, fr, es]);
        cubit
          ..toggleExtraTarget(ja)
          ..toggleExtraTarget(de);
      },
      verify: (cubit) {
        expect(cubit.state.extraTargets, const [pirate, fr, es, de]);
        expect(cubit.state.unavailableExtraTargets, const [pirate]);
        expect(saved(), const [
          [pirate, fr, es],
          [pirate, fr, es, de],
        ]);
      },
    );

    group('changed elsewhere', () {
      late StreamController<AppSettings> settings;

      setUp(() {
        settings = StreamController<AppSettings>();
        addTearDown(settings.close);
        whenListen(
          mocks.settings,
          settings.stream,
          initialState: const AppSettings(extraTargets: [fr]),
        );
      });

      Future<void> change(AppSettings value) async {
        settings.add(value);
        await Future<void>.delayed(Duration.zero);
      }

      blocTest<TranslateCubit, TranslateState>(
        'are applied (the ones the engine offers)',
        build: () => mocks.build(),
        act: (cubit) async {
          await cubit.loadEngines();
          expect(cubit.state.extraTargets, const [fr]);
          await change(const AppSettings(extraTargets: [ja, es, de]));
          expect(cubit.state.activeExtraTargets, const [es, de]);
          // Other settings changes leave them alone.
          await change(const AppSettings(extraTargets: [ja, es, de]));
          await change(
            const AppSettings(extraTargets: [ja, es, de], pureBlack: true),
          );
        },
        verify: (cubit) {
          expect(cubit.state.extraTargets, const [ja, es, de]);
          expect(cubit.state.unavailableExtraTargets, const [ja]);
          verifyNever(() => mocks.settings.setExtraTargets(any()));
        },
      );

      blocTest<TranslateCubit, TranslateState>(
        'are applied as they are while no engine is selected',
        build: () => mocks.build(),
        act: (cubit) => change(const AppSettings(extraTargets: [ja, es])),
        verify: (cubit) => expect(cubit.state.extraTargets, const [ja, es]),
      );

      blocTest<TranslateCubit, TranslateState>(
        'are translated right away when the input has a translation',
        setUp: () => mocks.stubTranslate(),
        build: () => mocks.build(),
        seed: () =>
            translated(extraTargets: const [fr])
                .copyWith(extraTranslations: [done(fr)]),
        act: (cubit) => change(const AppSettings(extraTargets: [fr, es])),
        verify: (cubit) {
          expect(requestedTargets(), ['es']);
          expect(cubit.state.extraTranslationFor(es)?.output, 'Hello->es');
        },
      );

      blocTest<TranslateCubit, TranslateState>(
        'that equal the languages in use change nothing',
        build: () => mocks.build(),
        seed: () => ready(extraTargets: const [es]),
        act: (cubit) async {
          cubit.setExtraTargets(const [es, de]);
          await change(const AppSettings(extraTargets: [es, de]));
        },
        expect: () => [
          ready(extraTargets: const [es, de]),
        ],
      );
    });

    test('quick changes are not undone by the settings catching up', () async {
      final repository = _MockSettingsRepository();
      when(() => repository.save(any())).thenAnswer((_) async {});
      final settings = SettingsCubit(
        repository: repository,
        initial: const AppSettings(extraTargets: [ja, fr]),
      );
      addTearDown(settings.close);
      final cubit = TranslateCubit(
        repository: mocks.repository,
        settings: settings,
        history: mocks.history,
      );
      addTearDown(cubit.close);
      await cubit.loadEngines();
      expect(cubit.state.activeExtraTargets, const [fr]);

      cubit
        ..toggleExtraTarget(es)
        ..toggleExtraTarget(de)
        ..toggleExtraTarget(fr);
      await Future<void>.delayed(Duration.zero);

      expect(cubit.state.extraTargets, const [ja, es, de]);
      expect(cubit.state.activeExtraTargets, const [es, de]);
      expect(settings.state.extraTargets, const [ja, es, de]);
    });

    group('text shared at start', () {
      /// The user's own DeepL API service (not an AI model).
      const deeplApi = TranslationEngine(
        id: 'mt:deepl',
        kind: EngineKind.mt,
        name: 'DeepL API',
        providerId: 'deepl',
      );

      Future<TranslateCubit> share(TranslationEngine engine) async {
        mocks
          ..stubSettings(
            AppSettings(
              extraTargets: const [fr, es],
              target: de,
              engineId: engine.id,
            ),
          )
          ..stubTranslate();
        when(() => mocks.repository.getEngines(refresh: any(named: 'refresh')))
            .thenAnswer((_) async => [engine]);
        final cubit = mocks.build();
        addTearDown(cubit.close);
        cubit.setExternalInput('Hello');
        await cubit.loadEngines();
        await Future<void>.delayed(Duration.zero);
        return cubit;
      }

      test('is translated into the saved extra targets where it is '
          'translated on its own (not an AI model)', () async {
        await share(deeplApi);
        expect(requestedTargets(), ['de', 'fr', 'es']);
      });

      test('waits for Translate with an AI model', () async {
        await share(claude);
        verifyNever(() => mocks.repository.translate(any(), any()));
      });
    });
  });
}
