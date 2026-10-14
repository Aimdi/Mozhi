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

  const genZ = Language.custom('Gen Z slang');

  group('custom source languages', () {
    blocTest<TranslateCubit, TranslateState>(
      'are accepted by AI engines with the general profile',
      setUp: () => mocks.stubTranslate(),
      build: () => mocks.build(),
      seed: () => readyState(engine: claude, input: 'no cap'),
      act: (cubit) {
        expect(cubit.state.supportsCustomLanguages, isTrue);
        cubit.setSource(genZ);
      },
      verify: (cubit) {
        expect(cubit.state.source, genZ);
        verify(() => mocks.settings.setLanguages(source: genZ)).called(1);
        verify(() => mocks.settings.addRecentLanguage(genZ)).called(1);
        expect(mocks.translateRequests().single.source, genZ);
      },
    );

    blocTest<TranslateCubit, TranslateState>(
      'are ignored by Mozhi and translation-only engines',
      build: () => mocks.build(),
      act: (cubit) {
        for (final engine in [google, gemma]) {
          cubit
            ..emit(readyState(engine: engine, input: 'x'))
            ..setSource(genZ);
          expect(cubit.state.supportsCustomLanguages, isFalse);
          expect(cubit.state.source, Language.auto);
        }
      },
      verify: (_) {
        verifyNever(
          () => mocks.settings.setLanguages(source: any(named: 'source')),
        );
      },
    );

    blocTest<TranslateCubit, TranslateState>(
      'are ignored before an engine is known',
      build: () => mocks.build(),
      act: (cubit) => cubit.setSource(genZ),
      expect: () => <TranslateState>[],
    );

    blocTest<TranslateCubit, TranslateState>(
      'are restored for AI engines and dropped for others',
      setUp: () {
        mocks.stubSettings(
          const AppSettings(engineId: 'ai:claude', source: genZ),
        );
      },
      build: () => mocks.build(),
      act: (cubit) async {
        await cubit.loadEngines();
        expect(cubit.state.engine, claude);
        expect(cubit.state.source, genZ);
        await cubit.selectEngine(google);
      },
      verify: (cubit) => expect(cubit.state.source, Language.auto),
    );

    blocTest<TranslateCubit, TranslateState>(
      'limit compare mode to engines that take custom languages',
      setUp: () {
        when(() => mocks.repository.compare(any(), any()))
            .thenAnswer((_) => const Stream.empty());
      },
      build: () => mocks.build(),
      seed: () => readyState(
        engine: claude,
        input: 'no cap',
        source: genZ,
        engines: [google, claude, gemma, local],
      ),
      act: (cubit) => cubit.runCompare(),
      verify: (_) {
        final engines =
            verify(() => mocks.repository.compare(captureAny(), any()))
                    .captured
                    .single
                as List<TranslationEngine>;
        expect(engines, [claude, local]);
      },
    );
  });

  group('recent source languages', () {
    const pairs = [
      LanguagePair(source: de, target: en),
      LanguagePair(source: Language.auto, target: fr),
      LanguagePair(source: genZ, target: en),
      LanguagePair(source: en, target: de),
      LanguagePair(
        source: Language(code: 'DE', name: 'German'),
        target: fr,
      ),
      LanguagePair(source: fr, target: en),
      LanguagePair(source: es, target: en),
      LanguagePair(source: ja, target: en),
      LanguagePair(
        source: Language(code: 'pt', name: 'Portuguese'),
        target: en,
      ),
    ];

    setUp(() => mocks.stubSettings(const AppSettings(recentPairs: pairs)));

    const expected = ['de', 'en', 'fr', 'es', 'ja'];

    blocTest<TranslateCubit, TranslateState>(
      'are sent with translations (sources of recent pairs, at most 5)',
      setUp: () => mocks.stubTranslate(),
      build: () => mocks.build(),
      seed: () => readyState(input: 'Gift'),
      act: (cubit) => cubit.translate(),
      verify: (_) {
        expect(
          mocks.translateRequests().single.recentSourceLanguages,
          expected,
        );
        expect(TranslateCubit.maxRecentSourceLanguages, 5);
      },
    );

    blocTest<TranslateCubit, TranslateState>(
      'are sent with compare runs',
      setUp: () {
        when(() => mocks.repository.compare(any(), any()))
            .thenAnswer((_) => const Stream.empty());
      },
      build: () => mocks.build(),
      seed: () => readyState(input: 'Gift'),
      act: (cubit) => cubit.runCompare(),
      verify: (_) {
        final request =
            verify(() => mocks.repository.compare(any(), captureAny()))
                    .captured
                    .single
                as TranslationRequest;
        expect(request.recentSourceLanguages, expected);
      },
    );

    blocTest<TranslateCubit, TranslateState>(
      'are sent with smart-swap re-translations and extras',
      setUp: () {
        when(() => mocks.repository.translate(any(), any()))
            .thenAnswer((_) => Stream.value(resultOf('Gift', detected: 'en')));
        when(() => mocks.repository.getInsights(any(), any(), any()))
            .thenAnswer((_) async => const []);
      },
      build: () => mocks.build(),
      seed: () => readyState(input: 'Gift'),
      act: (cubit) async {
        await cubit.translate();
        await cubit.loadInsights();
      },
      verify: (_) {
        final requests = mocks.translateRequests();
        expect(requests, hasLength(2));
        for (final request in requests) {
          expect(request.recentSourceLanguages, expected);
        }
        final extras =
            verify(
                  () =>
                      mocks.repository.getInsights(any(), captureAny(), any()),
                ).captured.single
                as TranslationRequest;
        expect(extras.recentSourceLanguages, expected);
      },
    );

    blocTest<TranslateCubit, TranslateState>(
      'are empty without recent pairs',
      setUp: () {
        mocks
          ..stubSettings(const AppSettings())
          ..stubTranslate();
      },
      build: () => mocks.build(),
      seed: () => readyState(input: 'Gift'),
      act: (cubit) => cubit.translate(),
      verify: (_) => expect(
        mocks.translateRequests().single.recentSourceLanguages,
        isEmpty,
      ),
    );
  });

  group('recent pairs', () {
    blocTest<TranslateCubit, TranslateState>(
      'records the detected source and the target after a translation',
      setUp: () => mocks.stubTranslate(resultOf('Hello', detected: 'de')),
      build: () => mocks.build(),
      seed: () => readyState(input: 'Hallo'),
      act: (cubit) => cubit.translate(),
      verify: (_) => verify(() => mocks.settings.recordPair(de, en)).called(1),
    );

    blocTest<TranslateCubit, TranslateState>(
      'records a selected source',
      setUp: () => mocks.stubTranslate(),
      build: () => mocks.build(),
      seed: () => readyState(input: 'Bonjour', source: fr, target: de),
      act: (cubit) => cubit.translate(),
      verify: (_) => verify(() => mocks.settings.recordPair(fr, de)).called(1),
    );

    blocTest<TranslateCubit, TranslateState>(
      'records auto when nothing usable was detected',
      setUp: () => mocks.stubTranslate(resultOf('x', detected: ' ')),
      build: () => mocks.build(),
      seed: () => readyState(input: 'x'),
      act: (cubit) => cubit.translate(),
      verify: (_) {
        verify(() => mocks.settings.recordPair(Language.auto, en)).called(1);
      },
    );

    blocTest<TranslateCubit, TranslateState>(
      'names detected languages the engine does not list from the catalogue',
      setUp: () => mocks.stubTranslate(resultOf('Hello', detected: 'ja')),
      build: () => mocks.build(),
      seed: () => readyState(input: 'こんにちは'),
      act: (cubit) => cubit.translate(),
      verify: (_) {
        final source =
            verify(() => mocks.settings.recordPair(captureAny(), en))
                    .captured
                    .single
                as Language;
        expect(source, ja);
        expect(source.name, 'Japanese');
      },
    );

    blocTest<TranslateCubit, TranslateState>(
      'records unknown detected languages as auto',
      setUp: () => mocks.stubTranslate(resultOf('Hello', detected: 'qqq')),
      build: () => mocks.build(),
      seed: () => readyState(input: '?'),
      act: (cubit) => cubit.translate(),
      verify: (_) {
        verify(() => mocks.settings.recordPair(Language.auto, en)).called(1);
      },
    );

    blocTest<TranslateCubit, TranslateState>(
      'does not record failed translations',
      setUp: () {
        when(() => mocks.repository.translate(any(), any()))
            .thenAnswer((_) => Stream.error(Exception('down')));
      },
      build: () => mocks.build(),
      seed: () => readyState(input: 'Hallo'),
      act: (cubit) => cubit.translate(),
      verify: (_) {
        verifyNever(() => mocks.settings.recordPair(any(), any()));
      },
    );
  });

  group('applyLanguagePair', () {
    blocTest<TranslateCubit, TranslateState>(
      'sets both languages and translates once',
      setUp: () => mocks.stubTranslate(),
      build: () => mocks.build(),
      seed: () => readyState(input: 'Hallo'),
      act: (cubit) =>
          cubit.applyLanguagePair(const LanguagePair(source: de, target: fr)),
      verify: (cubit) {
        expect(cubit.state.source, de);
        expect(cubit.state.target, fr);
        final request = mocks.translateRequests().single;
        expect((request.source, request.target), (de, fr));
        verify(() => mocks.settings.setLanguages(source: de)).called(1);
        verify(() => mocks.settings.setLanguages(target: fr)).called(1);
      },
    );

    blocTest<TranslateCubit, TranslateState>(
      'maps onto the engine lists and skips what the engine lacks',
      setUp: () => mocks.stubTranslate(),
      build: () => mocks.build(),
      seed: () => readyState(input: 'Hallo', target: fr),
      act: (cubit) => cubit.applyLanguagePair(
        const LanguagePair(
          source: Language(code: 'de-DE', name: 'German (Germany)'),
          target: ja,
        ),
      ),
      verify: (cubit) {
        expect(cubit.state.source, de);
        expect(cubit.state.target, fr);
        expect(mocks.translateRequests(), hasLength(1));
      },
    );

    blocTest<TranslateCubit, TranslateState>(
      'takes custom languages only on engines that support them',
      setUp: () => mocks.stubTranslate(),
      build: () => mocks.build(),
      act: (cubit) {
        cubit
          ..emit(readyState(input: 'hi', source: de))
          ..applyLanguagePair(const LanguagePair(source: genZ, target: pirate));
        expect((cubit.state.source, cubit.state.target), (de, en));
        cubit
          ..emit(readyState(engine: claude, input: 'hi', source: de))
          ..applyLanguagePair(
            const LanguagePair(source: Language.auto, target: pirate),
          );
        expect(cubit.state.source, Language.auto);
        expect(cubit.state.target, pirate);
      },
      verify: (_) => expect(mocks.translateRequests(), hasLength(1)),
    );

    blocTest<TranslateCubit, TranslateState>(
      'does nothing when the languages are already selected',
      build: () => mocks.build(),
      seed: () => readyState(input: 'hi'),
      act: (cubit) => cubit.applyLanguagePair(
        const LanguagePair(source: Language.auto, target: en),
      ),
      expect: () => <TranslateState>[],
    );

    blocTest<TranslateCubit, TranslateState>(
      'skips auto for engines that cannot detect',
      build: () => mocks.build(),
      seed: () =>
          readyState(source: de).copyWith(sourceLanguages: const [en, de]),
      act: (cubit) => cubit.applyLanguagePair(
        const LanguagePair(source: Language.auto, target: fr),
      ),
      verify: (cubit) {
        expect(cubit.state.source, de);
        expect(cubit.state.target, fr);
      },
    );

    blocTest<TranslateCubit, TranslateState>(
      'accepts auto when the source list is unknown',
      build: () => mocks.build(),
      seed: () => readyState(source: de).copyWith(sourceLanguages: const []),
      act: (cubit) => cubit.applyLanguagePair(
        const LanguagePair(source: Language.auto, target: en),
      ),
      verify: (cubit) => expect(cubit.state.source, Language.auto),
    );
  });

  group('selectPinnedTarget', () {
    const pins = [fr, ja, pirate, Language.auto, de];

    setUp(() {
      mocks.stubSettings(const AppSettings(pinnedLanguages: pins));
    });

    test('pinnedTargets are the pins the engine offers, as it lists them', () {
      // Google lists no Japanese and takes no custom languages.
      expect(readyState().pinnedTargets(pins), [fr, de]);
      expect(readyState(engine: claude).pinnedTargets(pins), [fr, pirate, de]);
      // Matched like any other language, without duplicates.
      expect(
        readyState().pinnedTargets(const [
          Language(code: 'de-DE', name: 'German (Germany)'),
          de,
        ]),
        [de],
      );
      expect(readyState().usableTarget(Language.auto), isNull);
    });

    blocTest<TranslateCubit, TranslateState>(
      'selects pin n of those the engine offers, like setTarget',
      setUp: () => mocks.stubTranslate(),
      build: () => mocks.build(),
      seed: () => readyState(input: 'hi'),
      act: (cubit) => cubit.selectPinnedTarget(1),
      verify: (cubit) {
        expect(cubit.state.target, de);
        expect(mocks.translateRequests().single.target, de);
        verify(() => mocks.settings.setLanguages(target: de)).called(1);
      },
    );

    blocTest<TranslateCubit, TranslateState>(
      'ignores indexes beyond the pins the engine offers',
      build: () => mocks.build(),
      seed: readyState,
      act: (cubit) => cubit
        ..selectPinnedTarget(-1)
        ..selectPinnedTarget(2)
        ..selectPinnedTarget(4),
      expect: () => <TranslateState>[],
    );

    blocTest<TranslateCubit, TranslateState>(
      'counts custom pins on AI engines',
      build: () => mocks.build(),
      seed: () => readyState(engine: claude),
      act: (cubit) => cubit.selectPinnedTarget(1),
      verify: (cubit) => expect(cubit.state.target, pirate),
    );
  });
}
