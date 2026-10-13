import 'dart:async';

import 'package:bloc_test/bloc_test.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:mocktail/mocktail.dart';
import 'package:mozhi/history/models/history_entry.dart';
import 'package:mozhi/quick_translate/quick_translate.dart';
import 'package:mozhi/settings/models/app_settings.dart';
import 'package:translation_repository/translation_repository.dart';

import '../helpers/helpers.dart';

void main() {
  setUpAll(registerQuickTranslateFallbacks);

  late MockTranslationRepository repository;
  late MockSettingsCubit settings;
  late MockHistoryCubit history;

  setUp(() {
    repository = MockTranslationRepository();
    settings = mockSettings(const AppSettings(target: french));
    history = MockHistoryCubit();
    when(() => history.add(any())).thenAnswer((_) async {});
    when(() => repository.getEngines(refresh: any(named: 'refresh')))
        .thenAnswer((_) async => const [deepl, google, claude]);
    when(() => repository.getTargetLanguages(any()))
        .thenAnswer((_) async => mozhiTargets);
    when(() => repository.translate(any(), any()))
        .thenAnswer((_) => Stream.value(result('Bonjour le monde')));
  });

  QuickTranslateCubit build({
    String text = 'Hello world',
    Language? target,
    bool withHistory = true,
  }) => QuickTranslateCubit(
    repository: repository,
    settings: settings,
    history: withHistory ? history : null,
    text: text,
    target: target,
  );

  QuickTranslateState loaded({
    String text = 'Hello world',
    Language target = french,
    TranslationEngine engine = google,
  }) => QuickTranslateState(
    text: text,
    target: target,
    engines: const [deepl, google, claude],
    engine: engine,
    targetLanguages: mozhiTargets,
  );

  group('QuickTranslateCubit', () {
    test('starts loading with the settings target', () {
      final cubit = build();
      expect(
        cubit.state,
        const QuickTranslateState(text: 'Hello world', target: french),
      );
      expect(build(target: german).state.target, german);
    });

    group('start', () {
      blocTest<QuickTranslateCubit, QuickTranslateState>(
        'loads engines (default google) and translates right away',
        build: build,
        act: (cubit) => cubit.start(),
        expect: () => [
          loaded(),
          loaded().copyWith(status: QuickTranslateStatus.translating),
          loaded().copyWith(
            status: QuickTranslateStatus.success,
            result: () => result('Bonjour le monde'),
          ),
        ],
        verify: (_) {
          verify(
            () => repository.translate(
              google,
              const TranslationRequest(
                text: 'Hello world',
                source: Language.auto,
                target: french,
              ),
            ),
          ).called(1);
          verify(() => repository.getEngines()).called(1);
        },
      );

      blocTest<QuickTranslateCubit, QuickTranslateState>(
        'prefers the engine selected in settings',
        setUp: () {
          when(() => settings.state).thenReturn(
            const AppSettings(target: french, engineId: 'mozhi:deepl'),
          );
          when(() => repository.translate(any(), any()))
              .thenAnswer((_) => const Stream.empty());
        },
        build: build,
        act: (cubit) => cubit.start(),
        verify: (cubit) {
          expect(cubit.state.engine, deepl);
          verify(() => repository.translate(deepl, any())).called(1);
        },
      );

      blocTest<QuickTranslateCubit, QuickTranslateState>(
        'falls back to the first engine without google',
        setUp: () {
          when(() => repository.getEngines(refresh: any(named: 'refresh')))
              .thenAnswer((_) async => const [claude, deepl]);
        },
        build: build,
        act: (cubit) => cubit.start(),
        verify: (cubit) => expect(cubit.state.engine, claude),
      );

      blocTest<QuickTranslateCubit, QuickTranslateState>(
        'maps the target onto the engine languages (English fallback)',
        setUp: () {
          when(() => repository.getTargetLanguages(any())).thenAnswer(
            (_) async => const [
              Language(code: 'fr-FR', name: 'French'),
              english,
            ],
          );
          when(() => repository.translate(any(), any()))
              .thenAnswer((_) => const Stream.empty());
        },
        build: () => build(target: const Language.custom('Pirate speak')),
        act: (cubit) => cubit.start(),
        verify: (cubit) => expect(cubit.state.target, english),
      );

      blocTest<QuickTranslateCubit, QuickTranslateState>(
        'keeps a custom target on AI engines',
        setUp: () {
          when(() => repository.getEngines(refresh: any(named: 'refresh')))
              .thenAnswer((_) async => const [claude]);
        },
        build: () => build(target: const Language.custom('Pirate speak')),
        act: (cubit) => cubit.start(),
        verify: (cubit) =>
            expect(cubit.state.target, const Language.custom('Pirate speak')),
      );

      blocTest<QuickTranslateCubit, QuickTranslateState>(
        'keeps the target when the engine reports no languages',
        setUp: () {
          when(() => repository.getTargetLanguages(any()))
              .thenAnswer((_) async => const []);
        },
        build: () => build(target: german),
        act: (cubit) => cubit.start(),
        verify: (cubit) => expect(cubit.state.target, german),
      );

      blocTest<QuickTranslateCubit, QuickTranslateState>(
        'replaces a custom target on Mozhi engines without languages',
        setUp: () {
          when(() => repository.getTargetLanguages(any()))
              .thenAnswer((_) async => const []);
        },
        build: () => build(target: const Language.custom('Pirate speak')),
        act: (cubit) => cubit.start(),
        verify: (cubit) => expect(cubit.state.target.code, 'en'),
      );

      blocTest<QuickTranslateCubit, QuickTranslateState>(
        'emits noEngines when nothing is available',
        setUp: () {
          when(() => repository.getEngines(refresh: any(named: 'refresh')))
              .thenAnswer((_) async => const []);
        },
        build: build,
        act: (cubit) => cubit.start(),
        expect: () => [
          const QuickTranslateState(
            text: 'Hello world',
            target: french,
            status: QuickTranslateStatus.noEngines,
          ),
        ],
        verify: (_) => verifyNever(() => repository.translate(any(), any())),
      );

      final failure = Exception('offline');

      blocTest<QuickTranslateCubit, QuickTranslateState>(
        'emits failure when the engines cannot be loaded',
        setUp: () {
          when(() => repository.getEngines(refresh: any(named: 'refresh')))
              .thenThrow(failure);
        },
        build: build,
        act: (cubit) => cubit.start(),
        expect: () => [
          QuickTranslateState(
            text: 'Hello world',
            target: french,
            status: QuickTranslateStatus.failure,
            error: failure,
          ),
        ],
      );

      blocTest<QuickTranslateCubit, QuickTranslateState>(
        'emits failure when the languages cannot be loaded',
        setUp: () {
          when(() => repository.getTargetLanguages(any())).thenThrow(failure);
        },
        build: build,
        act: (cubit) => cubit.start(),
        verify: (cubit) {
          expect(cubit.state.status, QuickTranslateStatus.failure);
          expect(cubit.state.error, failure);
        },
      );

      blocTest<QuickTranslateCubit, QuickTranslateState>(
        'ignores a load superseded by a newer one',
        setUp: () {
          var calls = 0;
          when(() => repository.getEngines(refresh: any(named: 'refresh')))
              .thenAnswer((_) async {
                calls++;
                if (calls == 1) {
                  await Future<void>.delayed(const Duration(milliseconds: 20));
                  throw failure;
                }
                return const [google];
              });
        },
        build: build,
        act: (cubit) async {
          final first = cubit.start();
          await cubit.start(refresh: true);
          await first;
        },
        verify: (cubit) {
          expect(cubit.state.status, QuickTranslateStatus.success);
          expect(cubit.state.error, isNull);
        },
      );

      blocTest<QuickTranslateCubit, QuickTranslateState>(
        'treats blank text as nothing to translate',
        build: () => build(text: '   '),
        act: (cubit) => cubit.start(),
        verify: (cubit) {
          expect(cubit.state.status, QuickTranslateStatus.success);
          expect(cubit.state.result, isNull);
          verifyNever(() => repository.translate(any(), any()));
        },
      );
    });

    group('translate', () {
      blocTest<QuickTranslateCubit, QuickTranslateState>(
        'does nothing without an engine',
        build: build,
        act: (cubit) => cubit.translate(),
        expect: () => <QuickTranslateState>[],
      );

      blocTest<QuickTranslateCubit, QuickTranslateState>(
        'streams partial results (AI) and completes',
        setUp: () {
          when(() => repository.translate(any(), any())).thenAnswer(
            (_) => Stream.fromIterable([
              result('Bon', engineId: 'ai:claude', isComplete: false),
              result('Bonjour', engineId: 'ai:claude', isComplete: false),
              result('Bonjour le monde', engineId: 'ai:claude'),
            ]),
          );
        },
        build: build,
        seed: () => loaded(engine: claude),
        act: (cubit) => cubit.translate(),
        expect: () => [
          loaded(engine: claude)
              .copyWith(status: QuickTranslateStatus.translating),
          loaded(engine: claude).copyWith(
            status: QuickTranslateStatus.translating,
            result: () =>
                result('Bon', engineId: 'ai:claude', isComplete: false),
          ),
          loaded(engine: claude).copyWith(
            status: QuickTranslateStatus.translating,
            result: () =>
                result('Bonjour', engineId: 'ai:claude', isComplete: false),
          ),
          loaded(engine: claude).copyWith(
            status: QuickTranslateStatus.success,
            result: () => result('Bonjour le monde', engineId: 'ai:claude'),
          ),
        ],
      );

      test('reports streaming state through the getters', () async {
        final controller = StreamController<TranslationResult>();
        when(() => repository.translate(any(), any()))
            .thenAnswer((_) => controller.stream);
        final cubit = build();
        addTearDown(cubit.close);
        final done = cubit.start();
        await pumpEventQueue();
        expect(cubit.state.isTranslating, isTrue);
        expect(cubit.state.isStreaming, isFalse);
        controller.add(result('Bon', isComplete: false));
        await pumpEventQueue();
        expect(cubit.state.isStreaming, isTrue);
        expect(cubit.state.hasTranslation, isFalse);
        expect(cubit.state.translation, 'Bon');
        controller.add(result('Bonjour'));
        await controller.close();
        await done;
        expect(cubit.state.hasTranslation, isTrue);
        expect(cubit.state.detectedSource, 'en');
      });

      blocTest<QuickTranslateCubit, QuickTranslateState>(
        'completes a stream that ends without a final result',
        setUp: () {
          when(() => repository.translate(any(), any())).thenAnswer(
            (_) => Stream.value(result('Bonjour', isComplete: false)),
          );
        },
        build: build,
        seed: loaded,
        act: (cubit) => cubit.translate(),
        verify: (cubit) {
          expect(cubit.state.status, QuickTranslateStatus.success);
          expect(cubit.state.result, result('Bonjour'));
          verify(() => history.add(any())).called(1);
        },
      );

      blocTest<QuickTranslateCubit, QuickTranslateState>(
        'succeeds without a result when the stream is empty',
        setUp: () {
          when(() => repository.translate(any(), any()))
              .thenAnswer((_) => const Stream.empty());
        },
        build: build,
        seed: loaded,
        act: (cubit) => cubit.translate(),
        verify: (cubit) {
          expect(cubit.state.status, QuickTranslateStatus.success);
          expect(cubit.state.result, isNull);
          expect(cubit.state.hasTranslation, isFalse);
          verifyNever(() => history.add(any()));
        },
      );

      final error = Exception('boom');

      blocTest<QuickTranslateCubit, QuickTranslateState>(
        'emits failure on a stream error',
        setUp: () {
          when(() => repository.translate(any(), any()))
              .thenAnswer((_) => Stream.error(error));
        },
        build: build,
        seed: loaded,
        act: (cubit) => cubit.translate(),
        expect: () => [
          loaded().copyWith(status: QuickTranslateStatus.translating),
          loaded().copyWith(
            status: QuickTranslateStatus.failure,
            error: () => error,
          ),
        ],
      );

      blocTest<QuickTranslateCubit, QuickTranslateState>(
        'emits failure when the request cannot be started',
        setUp: () {
          when(() => repository.translate(any(), any())).thenThrow(error);
        },
        build: build,
        seed: loaded,
        act: (cubit) => cubit.translate(),
        verify: (cubit) {
          expect(cubit.state.status, QuickTranslateStatus.failure);
          expect(cubit.state.error, error);
        },
      );

      test('a new translation cancels the previous one', () async {
        final first = StreamController<TranslationResult>();
        var calls = 0;
        when(() => repository.translate(any(), any())).thenAnswer((_) {
          calls++;
          return calls == 1 ? first.stream : Stream.value(result('Second'));
        });
        final cubit = build();
        addTearDown(cubit.close);
        final superseded = cubit.start();
        await pumpEventQueue();
        expect(first.hasListener, isTrue);
        await cubit.translate();
        await superseded;
        expect(first.hasListener, isFalse);
        expect(cubit.state.translation, 'Second');
        await first.close();
      });

      test('close cancels the running translation', () async {
        final controller = StreamController<TranslationResult>();
        when(() => repository.translate(any(), any()))
            .thenAnswer((_) => controller.stream);
        final cubit = build();
        final done = cubit.start();
        await pumpEventQueue();
        expect(controller.hasListener, isTrue);
        await cubit.close();
        await done;
        expect(controller.hasListener, isFalse);
        await controller.close();
      });
    });

    group('retry', () {
      blocTest<QuickTranslateCubit, QuickTranslateState>(
        'reloads the engines when they failed',
        setUp: () {
          var calls = 0;
          when(() => repository.getEngines(refresh: any(named: 'refresh')))
              .thenAnswer((_) async {
                if (calls++ == 0) throw Exception('offline');
                return const [google];
              });
        },
        build: build,
        act: (cubit) async {
          await cubit.start();
          await cubit.retry();
        },
        verify: (cubit) {
          expect(cubit.state.status, QuickTranslateStatus.success);
          expect(cubit.state.translation, 'Bonjour le monde');
          verify(() => repository.getEngines(refresh: true)).called(1);
        },
      );

      blocTest<QuickTranslateCubit, QuickTranslateState>(
        'translates again after a translation error',
        setUp: () {
          var calls = 0;
          when(() => repository.translate(any(), any())).thenAnswer(
            (_) => calls++ == 0
                ? Stream.error(Exception('boom'))
                : Stream.value(result('Bonjour le monde')),
          );
        },
        build: build,
        act: (cubit) async {
          await cubit.start();
          expect(cubit.state.status, QuickTranslateStatus.failure);
          await cubit.retry();
        },
        verify: (cubit) {
          expect(cubit.state.status, QuickTranslateStatus.success);
          expect(cubit.state.error, isNull);
          verifyNever(() => repository.getEngines(refresh: true));
        },
      );
    });

    group('setTarget', () {
      blocTest<QuickTranslateCubit, QuickTranslateState>(
        'persists the target and re-translates',
        build: build,
        seed: () => loaded().copyWith(
          status: QuickTranslateStatus.success,
          result: () => result('Bonjour le monde'),
        ),
        act: (cubit) => cubit.setTarget(german),
        expect: () => [
          loaded(target: german).copyWith(
            status: QuickTranslateStatus.success,
            result: () => result('Bonjour le monde'),
          ),
          loaded(target: german)
              .copyWith(status: QuickTranslateStatus.translating),
          loaded(target: german).copyWith(
            status: QuickTranslateStatus.success,
            result: () => result('Bonjour le monde'),
          ),
        ],
        verify: (_) {
          verify(() => settings.setLanguages(target: german)).called(1);
          verify(() => settings.addRecentLanguage(german)).called(1);
          verify(
            () => repository.translate(
              google,
              const TranslationRequest(
                text: 'Hello world',
                source: Language.auto,
                target: german,
              ),
            ),
          ).called(1);
        },
      );

      blocTest<QuickTranslateCubit, QuickTranslateState>(
        'does not re-translate the same target',
        build: build,
        seed: () => loaded().copyWith(status: QuickTranslateStatus.success),
        act: (cubit) => cubit.setTarget(french),
        expect: () => <QuickTranslateState>[],
        verify: (_) =>
            verify(() => settings.addRecentLanguage(french)).called(1),
      );

      blocTest<QuickTranslateCubit, QuickTranslateState>(
        're-translates the same target after a failure',
        build: build,
        seed: () => loaded().copyWith(status: QuickTranslateStatus.failure),
        act: (cubit) => cubit.setTarget(french),
        verify: (cubit) =>
            expect(cubit.state.status, QuickTranslateStatus.success),
      );

      blocTest<QuickTranslateCubit, QuickTranslateState>(
        'ignores auto and custom targets on Mozhi engines',
        build: build,
        seed: loaded,
        act: (cubit) async {
          await cubit.setTarget(Language.auto);
          await cubit.setTarget(const Language.custom('Pirate speak'));
        },
        expect: () => <QuickTranslateState>[],
        verify: (_) => verifyNever(
          () => settings.setLanguages(target: any(named: 'target')),
        ),
      );

      blocTest<QuickTranslateCubit, QuickTranslateState>(
        'accepts custom targets on AI engines',
        build: build,
        seed: () => loaded(engine: claude),
        act: (cubit) => cubit.setTarget(const Language.custom('Pirate speak')),
        verify: (cubit) {
          expect(cubit.state.target, const Language.custom('Pirate speak'));
          expect(cubit.state.allowsCustomTarget, isTrue);
        },
      );
    });

    group('selectEngine', () {
      blocTest<QuickTranslateCubit, QuickTranslateState>(
        'persists the engine, reloads languages and re-translates',
        setUp: () {
          when(() => repository.getTargetLanguages(deepl))
              .thenAnswer((_) async => const [english, german]);
          when(() => repository.translate(any(), any())).thenAnswer(
            (_) => Stream.value(result('Hello world', detectedSource: 'fr')),
          );
        },
        build: build,
        seed: () => loaded().copyWith(status: QuickTranslateStatus.success),
        act: (cubit) => cubit.selectEngine(deepl),
        verify: (cubit) {
          verify(() => settings.setEngine('mozhi:deepl')).called(1);
          expect(cubit.state.engine, deepl);
          expect(cubit.state.targetLanguages, const [english, german]);
          // French is not offered by this engine: English fallback.
          expect(cubit.state.target, english);
          expect(cubit.state.status, QuickTranslateStatus.success);
          verify(() => repository.translate(deepl, any())).called(1);
        },
      );

      blocTest<QuickTranslateCubit, QuickTranslateState>(
        'ignores the selected engine',
        build: build,
        seed: () => loaded().copyWith(status: QuickTranslateStatus.success),
        act: (cubit) => cubit.selectEngine(google),
        expect: () => <QuickTranslateState>[],
      );

      final error = Exception('offline');

      blocTest<QuickTranslateCubit, QuickTranslateState>(
        'emits failure when the languages cannot be loaded',
        setUp: () {
          when(() => repository.getTargetLanguages(deepl)).thenThrow(error);
        },
        build: build,
        seed: loaded,
        act: (cubit) => cubit.selectEngine(deepl),
        verify: (cubit) {
          expect(cubit.state.status, QuickTranslateStatus.failure);
          expect(cubit.state.error, error);
          expect(cubit.state.engine, deepl);
        },
      );

      blocTest<QuickTranslateCubit, QuickTranslateState>(
        'drops languages of a superseded switch',
        setUp: () {
          when(() => repository.getTargetLanguages(deepl))
              .thenAnswer((_) async {
                await Future<void>.delayed(const Duration(milliseconds: 20));
                throw error;
              });
        },
        build: build,
        seed: loaded,
        act: (cubit) async {
          final first = cubit.selectEngine(deepl);
          await cubit.selectEngine(claude);
          await first;
        },
        verify: (cubit) {
          expect(cubit.state.engine, claude);
          expect(cubit.state.status, QuickTranslateStatus.success);
        },
      );
    });

    group('smart target switch', () {
      setUp(() {
        when(() => settings.state).thenReturn(
          const AppSettings(
            target: english,
            recentLanguages: [english, german],
          ),
        );
      });

      blocTest<QuickTranslateCubit, QuickTranslateState>(
        'switches to the most recent other language once',
        setUp: () {
          when(() => repository.translate(any(), any()))
              .thenAnswer((invocation) {
                final request =
                    invocation.positionalArguments[1] as TranslationRequest;
                return Stream.value(
                  request.target == english
                      ? result('Hello world')
                      : result('Hallo Welt'),
                );
              });
        },
        build: build,
        act: (cubit) => cubit.start(),
        verify: (cubit) {
          expect(cubit.state.target, german);
          expect(cubit.state.translation, 'Hallo Welt');
          verifyNever(() => settings.setLanguages(target: german));
          verify(() => history.add(any())).called(1);
        },
      );

      blocTest<QuickTranslateCubit, QuickTranslateState>(
        'falls back to English, then the first other language',
        setUp: () {
          when(() => settings.state).thenReturn(
            const AppSettings(target: french, recentLanguages: [french]),
          );
          when(() => repository.translate(any(), any())).thenAnswer(
            (_) => Stream.value(result('Bonjour', detectedSource: 'fr')),
          );
        },
        build: build,
        act: (cubit) => cubit.start(),
        verify: (cubit) => expect(cubit.state.target, english),
      );

      blocTest<QuickTranslateCubit, QuickTranslateState>(
        'uses the first other target when English is the detected language',
        setUp: () {
          when(() => settings.state).thenReturn(
            const AppSettings(target: english, recentLanguages: [english]),
          );
          when(() => repository.translate(any(), any()))
              .thenAnswer((_) => Stream.value(result('Hello')));
        },
        build: build,
        act: (cubit) => cubit.start(),
        verify: (cubit) => expect(cubit.state.target, french),
      );

      blocTest<QuickTranslateCubit, QuickTranslateState>(
        'keeps a target the user picked',
        setUp: () {
          when(() => repository.translate(any(), any()))
              .thenAnswer((_) => Stream.value(result('Hello world')));
        },
        build: build,
        seed: loaded,
        act: (cubit) => cubit.setTarget(english),
        verify: (cubit) => expect(cubit.state.target, english),
      );

      blocTest<QuickTranslateCubit, QuickTranslateState>(
        'does nothing without a detected language',
        setUp: () {
          when(() => repository.translate(any(), any())).thenAnswer(
            (_) => Stream.value(result('Hello world', detectedSource: null)),
          );
        },
        build: build,
        act: (cubit) => cubit.start(),
        verify: (cubit) => expect(cubit.state.target, english),
      );

      blocTest<QuickTranslateCubit, QuickTranslateState>(
        'does nothing when no other language is available',
        setUp: () {
          when(() => repository.getTargetLanguages(any()))
              .thenAnswer((_) async => const [english]);
          when(() => repository.translate(any(), any()))
              .thenAnswer((_) => Stream.value(result('Hello world')));
        },
        build: build,
        act: (cubit) => cubit.start(),
        verify: (cubit) => expect(cubit.state.target, english),
      );
    });

    group('history', () {
      blocTest<QuickTranslateCubit, QuickTranslateState>(
        'records completed translations',
        build: build,
        act: (cubit) => cubit.start(),
        verify: (_) {
          final entry =
              verify(() => history.add(captureAny())).captured.single
                  as HistoryEntry;
          expect(entry.text, 'Hello world');
          expect(entry.translation, 'Bonjour le monde');
          expect(entry.target, french);
          expect(entry.source, Language.auto);
          expect(entry.engineId, 'mozhi:google');
          expect(entry.engineName, 'Google');
          expect(entry.detectedSource, 'en');
        },
      );

      blocTest<QuickTranslateCubit, QuickTranslateState>(
        'skips history when disabled',
        setUp: () {
          when(
            () => settings.state,
          ).thenReturn(const AppSettings(target: french, saveHistory: false));
        },
        build: build,
        act: (cubit) => cubit.start(),
        verify: (_) => verifyNever(() => history.add(any())),
      );

      blocTest<QuickTranslateCubit, QuickTranslateState>(
        'works without a history cubit',
        build: () => build(withHistory: false),
        act: (cubit) => cubit.start(),
        verify: (cubit) =>
            expect(cubit.state.status, QuickTranslateStatus.success),
      );

      blocTest<QuickTranslateCubit, QuickTranslateState>(
        'reports history errors via addError',
        setUp: () {
          when(() => history.add(any()))
              .thenAnswer((_) => Future.error(StateError('disk full')));
        },
        build: build,
        act: (cubit) => cubit.start(),
        errors: () => [isA<StateError>()],
      );
    });

    test('pickerLanguages combines settings and engine languages', () async {
      when(() => settings.state).thenReturn(
        const AppSettings(
          target: french,
          recentLanguages: [german],
          pinnedLanguages: [japanese],
        ),
      );
      final cubit = build();
      addTearDown(cubit.close);
      await cubit.start();
      final languages = cubit.pickerLanguages(preferredCodes: ['fr']);
      expect(languages.recent, const [japanese, german]);
      expect(languages.common.first, french);
      expect(languages.common, contains(english));
      expect(languages.all, mozhiTargets);
    });
  });
}
