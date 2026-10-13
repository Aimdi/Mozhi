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

  group('setInput', () {
    blocTest<TranslateCubit, TranslateState>(
      'does nothing for unchanged text',
      build: () => mocks.build(),
      seed: () => readyState(input: 'hi'),
      act: (cubit) => cubit.setInput('hi'),
      expect: () => <TranslateState>[],
    );

    blocTest<TranslateCubit, TranslateState>(
      'updates input, clears extras and translates after the debounce',
      setUp: () => mocks.stubTranslate(),
      build: () => mocks.build(),
      seed: () => readyState().copyWith(
        insightsStatus: ExtraStatus.ready,
        insights: const [WordInsight(sourceText: 'a', targetText: 'b')],
      ),
      act: (cubit) async {
        cubit.setInput('hallo');
        expect(cubit.state.input, 'hallo');
        expect(cubit.state.insights, isEmpty);
        expect(cubit.state.insightsStatus, ExtraStatus.idle);
        verifyNever(() => mocks.repository.translate(any(), any()));
        await Future<void>.delayed(afterDebounce);
      },
      verify: (cubit) {
        expect(mocks.translateRequests().single.text, 'hallo');
        expect(cubit.state.output, 'hallo->en');
      },
    );

    blocTest<TranslateCubit, TranslateState>(
      'restarts the debounce on every keystroke',
      setUp: () => mocks.stubTranslate(),
      build: () => mocks.build(),
      seed: readyState,
      act: (cubit) async {
        cubit.setInput('h');
        await Future<void>.delayed(const Duration(milliseconds: 5));
        cubit.setInput('ha');
        await Future<void>.delayed(const Duration(milliseconds: 5));
        cubit.setInput('hal');
        await Future<void>.delayed(afterDebounce);
      },
      verify: (_) {
        expect(mocks.translateRequests().map((r) => r.text), ['hal']);
      },
    );

    blocTest<TranslateCubit, TranslateState>(
      'does not translate when instant translate is off (Mozhi)',
      setUp: () {
        mocks
          ..stubTranslate()
          ..stubSettings(const AppSettings(instantTranslate: false));
      },
      build: () => mocks.build(),
      seed: readyState,
      act: (cubit) async {
        cubit.setInput('hallo');
        await Future<void>.delayed(afterDebounce);
      },
      verify: (_) {
        verifyNever(() => mocks.repository.translate(any(), any()));
      },
    );

    blocTest<TranslateCubit, TranslateState>(
      'does not translate AI engines by default',
      setUp: () => mocks.stubTranslate(),
      build: () => mocks.build(),
      seed: () => readyState(engine: claude),
      act: (cubit) async {
        cubit.setInput('hallo');
        await Future<void>.delayed(afterDebounce);
      },
      verify: (_) {
        verifyNever(() => mocks.repository.translate(any(), any()));
      },
    );

    blocTest<TranslateCubit, TranslateState>(
      'uses the longer AI debounce when instantTranslateAi is on',
      setUp: () {
        mocks
          ..stubTranslate()
          ..stubSettings(const AppSettings(instantTranslateAi: true));
      },
      build: () => mocks.build(),
      seed: () => readyState(engine: claude),
      act: (cubit) async {
        cubit.setInput('hallo');
        await Future<void>.delayed(const Duration(milliseconds: 25));
        verifyNever(() => mocks.repository.translate(any(), any()));
        await Future<void>.delayed(afterDebounce);
      },
      verify: (_) {
        verify(() => mocks.repository.translate(claude, any())).called(1);
      },
    );

    blocTest<TranslateCubit, TranslateState>(
      'does not translate without an engine',
      setUp: () => mocks.stubTranslate(),
      build: () => mocks.build(),
      act: (cubit) async {
        cubit.setInput('hallo');
        await Future<void>.delayed(afterDebounce);
      },
      verify: (cubit) {
        expect(cubit.state.input, 'hallo');
        verifyNever(() => mocks.repository.translate(any(), any()));
      },
    );

    blocTest<TranslateCubit, TranslateState>(
      'does not auto-translate in compare mode and drops compare entries',
      setUp: () => mocks.stubTranslate(),
      build: () => mocks.build(),
      seed: () => readyState(input: 'a').copyWith(
        compareMode: true,
        compareEntries: [CompareEntry.success(resultOf('x'))],
      ),
      act: (cubit) async {
        cubit.setInput('hallo');
        await Future<void>.delayed(afterDebounce);
      },
      verify: (cubit) {
        expect(cubit.state.compareEntries, isEmpty);
        verifyNever(() => mocks.repository.translate(any(), any()));
        verifyNever(() => mocks.repository.compare(any(), any()));
      },
    );

    final previous = resultOf('alt');

    blocTest<TranslateCubit, TranslateState>(
      'clearing the text cancels the translation and resets the result',
      setUp: () {
        when(() => mocks.repository.translate(any(), any()))
            .thenAnswer((_) => StreamController<TranslationResult>().stream);
      },
      build: () => mocks.build(),
      seed: () => readyState(
        input: 'hallo',
        result: previous,
        status: TranslateStatus.success,
      ),
      act: (cubit) async {
        unawaited(cubit.translate());
        cubit.setInput('  ');
      },
      expect: () => [
        readyState(
          input: 'hallo',
          result: previous,
          status: TranslateStatus.translating,
        ),
        readyState(input: '  '),
      ],
    );

    blocTest<TranslateCubit, TranslateState>(
      'clearing the text cancels a pending debounce',
      setUp: () => mocks.stubTranslate(),
      build: () => mocks.build(),
      seed: readyState,
      act: (cubit) async {
        cubit
          ..setInput('hallo')
          ..setInput('');
        await Future<void>.delayed(afterDebounce);
      },
      verify: (_) {
        verifyNever(() => mocks.repository.translate(any(), any()));
      },
    );
  });

  group('setInputAndTranslate', () {
    blocTest<TranslateCubit, TranslateState>(
      'translates immediately',
      setUp: () => mocks.stubTranslate(),
      build: () => mocks.build(),
      seed: readyState,
      act: (cubit) async {
        cubit.setInputAndTranslate('shared');
        expect(cubit.state.status, TranslateStatus.translating);
        await Future<void>.delayed(afterDebounce);
      },
      verify: (cubit) {
        expect(mocks.translateRequests().map((r) => r.text), ['shared']);
        expect(cubit.state.output, 'shared->en');
      },
    );

    blocTest<TranslateCubit, TranslateState>(
      're-translates the same text',
      setUp: () => mocks.stubTranslate(),
      build: () => mocks.build(),
      seed: () => readyState(input: 'shared'),
      act: (cubit) => cubit.setInputAndTranslate('shared'),
      verify: (_) {
        verify(() => mocks.repository.translate(any(), any())).called(1);
      },
    );
  });

  group('translate', () {
    blocTest<TranslateCubit, TranslateState>(
      'does nothing for blank input',
      build: () => mocks.build(),
      seed: () => readyState(input: '  '),
      act: (cubit) => cubit.translate(),
      expect: () => <TranslateState>[],
    );

    blocTest<TranslateCubit, TranslateState>(
      'does nothing without an engine',
      build: () => mocks.build(),
      seed: () => const TranslateState(input: 'hallo'),
      act: (cubit) => cubit.translate(),
      expect: () => <TranslateState>[],
    );

    final hallo = resultOf('hallo', detected: 'en');

    blocTest<TranslateCubit, TranslateState>(
      'emits translating then success and records history',
      setUp: () => mocks.stubTranslate(hallo),
      build: () => mocks.build(),
      seed: () => readyState(input: 'hello', target: de),
      act: (cubit) => cubit.translate(),
      expect: () => [
        readyState(
          input: 'hello',
          target: de,
          status: TranslateStatus.translating,
        ),
        readyState(
          input: 'hello',
          target: de,
          status: TranslateStatus.success,
          result: hallo,
        ),
      ],
      verify: (_) {
        final request = mocks.translateRequests().single;
        expect(
          request,
          const TranslationRequest(
            text: 'hello',
            source: Language.auto,
            target: de,
          ),
        );
        final entry = mocks.historyEntries().single;
        expect(entry.text, 'hello');
        expect(entry.translation, 'hallo');
        expect(entry.source, Language.auto);
        expect(entry.target, de);
        expect(entry.engineId, google.id);
        expect(entry.engineName, google.name);
        expect(entry.detectedSource, 'en');
        expect(entry.isFavorite, isFalse);
        expect(int.tryParse(entry.id), isNotNull);
      },
    );

    blocTest<TranslateCubit, TranslateState>(
      'does not record history when saveHistory is off',
      setUp: () {
        mocks
          ..stubTranslate(hallo)
          ..stubSettings(const AppSettings(saveHistory: false));
      },
      build: () => mocks.build(),
      seed: () => readyState(input: 'hello', target: de),
      act: (cubit) => cubit.translate(),
      verify: (cubit) {
        expect(cubit.state.status, TranslateStatus.success);
        verifyNever(() => mocks.history.add(any()));
      },
    );

    blocTest<TranslateCubit, TranslateState>(
      'does not record empty translations',
      setUp: () => mocks.stubTranslate(resultOf('  ')),
      build: () => mocks.build(),
      seed: () => readyState(input: 'hello', target: de),
      act: (cubit) => cubit.translate(),
      verify: (_) => verifyNever(() => mocks.history.add(any())),
    );

    final historyError = Exception('disk full');

    blocTest<TranslateCubit, TranslateState>(
      'reports history failures via addError',
      setUp: () {
        mocks.stubTranslate(hallo);
        when(() => mocks.history.add(any())).thenAnswer((_) async {
          throw historyError;
        });
      },
      build: () => mocks.build(),
      seed: () => readyState(input: 'hello', target: de),
      act: (cubit) async {
        await cubit.translate();
        await Future<void>.delayed(Duration.zero);
      },
      errors: () => [historyError],
    );

    final partial1 = resultOf('Hal', engine: claude, isComplete: false);
    final partial2 = resultOf('Hallo We', engine: claude, isComplete: false);
    final complete = resultOf('Hallo Welt', engine: claude);

    blocTest<TranslateCubit, TranslateState>(
      'streams snapshots and records history only on completion',
      setUp: () {
        final controller = StreamController<TranslationResult>();
        when(() => mocks.repository.translate(any(), any()))
            .thenAnswer((_) => controller.stream);
        addTearDown(controller.close);
        unawaited(
          Future<void>(() async {
            controller.add(partial1);
            await Future<void>.delayed(Duration.zero);
            verifyNever(() => mocks.history.add(any()));
            controller.add(partial2);
            await Future<void>.delayed(Duration.zero);
            verifyNever(() => mocks.history.add(any()));
            controller.add(complete);
            await controller.close();
          }),
        );
      },
      build: () => mocks.build(),
      seed: () => readyState(engine: claude, input: 'Hello world', target: de),
      act: (cubit) => cubit.translate(),
      expect: () {
        final base = readyState(
          engine: claude,
          input: 'Hello world',
          target: de,
        );
        return [
          base.copyWith(status: TranslateStatus.translating),
          base.copyWith(
            status: TranslateStatus.translating,
            result: () => partial1,
            resultInput: () => 'Hello world',
          ),
          base.copyWith(
            status: TranslateStatus.translating,
            result: () => partial2,
            resultInput: () => 'Hello world',
          ),
          base.copyWith(
            status: TranslateStatus.success,
            result: () => complete,
            resultInput: () => 'Hello world',
          ),
        ];
      },
      verify: (_) {
        final entry = mocks.historyEntries().single;
        expect(entry.translation, 'Hallo Welt');
        expect(entry.engineId, claude.id);
      },
    );

    final translateError = Exception('429');

    blocTest<TranslateCubit, TranslateState>(
      'emits failure on error and drops the result',
      setUp: () {
        when(() => mocks.repository.translate(any(), any()))
            .thenAnswer((_) => Stream.error(translateError));
      },
      build: () => mocks.build(),
      seed: () => readyState(input: 'hello', result: hallo),
      act: (cubit) => cubit.translate(),
      expect: () => [
        readyState(
          input: 'hello',
          result: hallo,
          status: TranslateStatus.translating,
        ),
        readyState(
          input: 'hello',
          status: TranslateStatus.failure,
        ).copyWith(error: () => translateError),
      ],
      verify: (_) => verifyNever(() => mocks.history.add(any())),
    );

    blocTest<TranslateCubit, TranslateState>(
      'emits failure when the repository throws synchronously',
      setUp: () {
        when(() => mocks.repository.translate(any(), any()))
            .thenThrow(translateError);
      },
      build: () => mocks.build(),
      seed: () => readyState(input: 'hello'),
      act: (cubit) => cubit.translate(),
      verify: (cubit) {
        expect(cubit.state.status, TranslateStatus.failure);
        expect(cubit.state.error, translateError);
      },
    );

    blocTest<TranslateCubit, TranslateState>(
      'returns to idle when the stream ends without results',
      setUp: () {
        when(() => mocks.repository.translate(any(), any()))
            .thenAnswer((_) => const Stream.empty());
      },
      build: () => mocks.build(),
      seed: () => readyState(input: 'hello'),
      act: (cubit) => cubit.translate(),
      expect: () => [
        readyState(input: 'hello', status: TranslateStatus.translating),
        readyState(input: 'hello'),
      ],
    );

    blocTest<TranslateCubit, TranslateState>(
      'succeeds when the stream ends after a partial result',
      setUp: () {
        when(() => mocks.repository.translate(any(), any()))
            .thenAnswer((_) => Stream.value(partial1));
      },
      build: () => mocks.build(),
      seed: () => readyState(engine: claude, input: 'hello'),
      act: (cubit) => cubit.translate(),
      verify: (cubit) {
        expect(cubit.state.status, TranslateStatus.success);
        expect(cubit.state.result, same(partial1));
        verifyNever(() => mocks.history.add(any()));
      },
    );

    blocTest<TranslateCubit, TranslateState>(
      'cancels the previous translation and ignores its events',
      setUp: () {
        final first = StreamController<TranslationResult>();
        final second = StreamController<TranslationResult>();
        addTearDown(first.close);
        addTearDown(second.close);
        var calls = 0;
        when(() => mocks.repository.translate(any(), any())).thenAnswer((_) {
          calls++;
          return calls == 1 ? first.stream : second.stream;
        });
        unawaited(
          Future<void>(() async {
            await Future<void>.delayed(const Duration(milliseconds: 5));
            expect(first.hasListener, isFalse);
            // Emitting on a cancelled stream reaches nobody.
            first.add(resultOf('stale'));
            second.add(resultOf('fresh'));
            await second.close();
          }),
        );
      },
      build: () => mocks.build(),
      seed: () => readyState(input: 'hello'),
      act: (cubit) async {
        final firstDone = cubit.translate();
        await Future<void>.delayed(Duration.zero);
        final secondDone = cubit.translate();
        await firstDone;
        await secondDone;
      },
      verify: (cubit) {
        expect(cubit.state.output, 'fresh');
        expect(cubit.state.status, TranslateStatus.success);
        verify(() => mocks.history.add(any())).called(1);
      },
    );

    blocTest<TranslateCubit, TranslateState>(
      'keeps the previous result visible while translating',
      setUp: () {
        when(() => mocks.repository.translate(any(), any()))
            .thenAnswer((_) => StreamController<TranslationResult>().stream);
      },
      build: () => mocks.build(),
      seed: () => readyState(
        input: 'hello',
        result: hallo,
        status: TranslateStatus.success,
      ),
      act: (cubit) => unawaited(cubit.translate()),
      expect: () => [
        readyState(
          input: 'hello',
          result: hallo,
          status: TranslateStatus.translating,
        ),
      ],
    );

    blocTest<TranslateCubit, TranslateState>(
      'runs compare in compare mode',
      setUp: () {
        when(() => mocks.repository.compare(any(), any()))
            .thenAnswer((_) => const Stream.empty());
      },
      build: () => mocks.build(),
      seed: () => readyState(input: 'hello').copyWith(compareMode: true),
      act: (cubit) => cubit.translate(),
      verify: (_) {
        verify(() => mocks.repository.compare(allEngines, any())).called(1);
        verifyNever(() => mocks.repository.translate(any(), any()));
      },
    );

    blocTest<TranslateCubit, TranslateState>(
      'ignores events after close',
      setUp: () {
        final controller = StreamController<TranslationResult>.broadcast();
        when(() => mocks.repository.translate(any(), any()))
            .thenAnswer((_) => controller.stream);
        addTearDown(controller.close);
      },
      build: () => mocks.build(),
      seed: () => readyState(input: 'hello'),
      act: (cubit) async {
        final done = cubit.translate();
        await cubit.close();
        await done;
      },
      expect: () => [
        readyState(input: 'hello', status: TranslateStatus.translating),
      ],
    );
  });

  group('smart swap', () {
    TranslationResult detected(String code, String text) =>
        resultOf(text, detected: code);

    void stubDetect(String code) {
      when(() => mocks.repository.translate(any(), any())).thenAnswer((
        invocation,
      ) {
        final request = invocation.positionalArguments[1] as TranslationRequest;
        return Stream.value(
          detected(code, '${request.text}->${request.target.code}'),
        );
      });
    }

    blocTest<TranslateCubit, TranslateState>(
      'switches to the most recent other language and re-translates once',
      setUp: () {
        stubDetect('en');
        mocks.stubSettings(
          const AppSettings(recentLanguages: [en, pirate, ja, fr, de]),
        );
      },
      build: () => mocks.build(),
      seed: () => readyState(input: 'hello'),
      act: (cubit) => cubit.translate(),
      verify: (cubit) {
        // ja is not a target of the engine; fr is the next candidate.
        expect(cubit.state.target, fr);
        expect(cubit.state.output, 'hello->fr');
        expect(cubit.state.status, TranslateStatus.success);
        expect(mocks.translateRequests().map((r) => r.target), [en, fr]);
        verify(() => mocks.settings.setLanguages(target: fr)).called(1);
        verify(() => mocks.settings.addRecentLanguage(fr)).called(1);
        expect(mocks.historyEntries().single.target, fr);
      },
    );

    blocTest<TranslateCubit, TranslateState>(
      'falls back to English when the detected language is not English',
      setUp: () => stubDetect('de'),
      build: () => mocks.build(),
      seed: () => readyState(input: 'hallo', target: de),
      act: (cubit) => cubit.translate(),
      verify: (cubit) {
        expect(cubit.state.target, en);
        expect(mocks.translateRequests().map((r) => r.target), [de, en]);
      },
    );

    blocTest<TranslateCubit, TranslateState>(
      'falls back to a widely used language for English text',
      setUp: () => stubDetect('en'),
      build: () => mocks.build(),
      seed: () => readyState(input: 'hello'),
      act: (cubit) => cubit.translate(),
      verify: (cubit) => expect(cubit.state.target, es),
    );

    blocTest<TranslateCubit, TranslateState>(
      'uses recent languages as-is when the target list is unknown',
      setUp: () {
        stubDetect('en');
        mocks.stubSettings(const AppSettings(recentLanguages: [ja]));
      },
      build: () => mocks.build(),
      seed: () => readyState(input: 'hello').copyWith(targetLanguages: []),
      act: (cubit) => cubit.translate(),
      verify: (cubit) => expect(cubit.state.target, ja),
    );

    blocTest<TranslateCubit, TranslateState>(
      'keeps the target when no other language exists',
      setUp: () => stubDetect('en'),
      build: () => mocks.build(),
      seed: () => readyState(input: 'hello').copyWith(targetLanguages: [en]),
      act: (cubit) => cubit.translate(),
      verify: (cubit) {
        expect(cubit.state.target, en);
        expect(cubit.state.status, TranslateStatus.success);
        verify(() => mocks.repository.translate(any(), any())).called(1);
      },
    );

    blocTest<TranslateCubit, TranslateState>(
      'does not swap for a selected source language',
      setUp: () => stubDetect('en'),
      build: () => mocks.build(),
      seed: () => readyState(input: 'hello', source: en),
      act: (cubit) => cubit.translate(),
      verify: (cubit) {
        expect(cubit.state.target, en);
        verify(() => mocks.repository.translate(any(), any())).called(1);
      },
    );

    blocTest<TranslateCubit, TranslateState>(
      'does not swap custom targets',
      setUp: () => stubDetect('Pirate speak'),
      build: () => mocks.build(),
      seed: () => readyState(engine: claude, input: 'hello', target: pirate),
      act: (cubit) => cubit.translate(),
      verify: (cubit) => expect(cubit.state.target, pirate),
    );

    blocTest<TranslateCubit, TranslateState>(
      'does not swap when nothing was detected',
      setUp: () => mocks.stubTranslate(resultOf('hello')),
      build: () => mocks.build(),
      seed: () => readyState(input: 'hello'),
      act: (cubit) => cubit.translate(),
      verify: (cubit) => expect(cubit.state.target, en),
    );

    blocTest<TranslateCubit, TranslateState>(
      'does not swap when the detected language differs from the target',
      setUp: () => stubDetect('de'),
      build: () => mocks.build(),
      seed: () => readyState(input: 'hallo'),
      act: (cubit) => cubit.translate(),
      verify: (cubit) {
        expect(cubit.state.target, en);
        verify(() => mocks.repository.translate(any(), any())).called(1);
      },
    );

    blocTest<TranslateCubit, TranslateState>(
      'never loops: the re-translation does not swap again',
      setUp: () {
        // The engine claims the text is always in the target language.
        when(() => mocks.repository.translate(any(), any()))
            .thenAnswer((invocation) {
              final request =
                  invocation.positionalArguments[1] as TranslationRequest;
              return Stream.value(detected(request.target.code, 'x'));
            });
      },
      build: () => mocks.build(),
      seed: () => readyState(input: 'bonjour', target: fr),
      act: (cubit) => cubit.translate(),
      verify: (cubit) {
        expect(cubit.state.target, en);
        verify(() => mocks.repository.translate(any(), any())).called(2);
      },
    );

    blocTest<TranslateCubit, TranslateState>(
      'is disabled after the user picks the swapped-away target again',
      setUp: () => stubDetect('en'),
      build: () => mocks.build(),
      seed: () => readyState(input: 'hello'),
      act: (cubit) async {
        await cubit.translate();
        expect(cubit.state.target, es);
        cubit.setTarget(en);
        await Future<void>.delayed(Duration.zero);
      },
      verify: (cubit) {
        expect(cubit.state.target, en);
        expect(cubit.state.output, 'hello->en');
        expect(mocks.translateRequests().map((r) => r.target), [en, es, en]);
      },
    );

    blocTest<TranslateCubit, TranslateState>(
      'picking a different target after a swap translates normally',
      setUp: () => stubDetect('en'),
      build: () => mocks.build(),
      seed: () => readyState(input: 'hello'),
      act: (cubit) async {
        await cubit.translate();
        cubit.setTarget(fr);
        await Future<void>.delayed(Duration.zero);
      },
      verify: (cubit) {
        expect(cubit.state.target, fr);
        expect(cubit.state.output, 'hello->fr');
      },
    );
  });

  group('setSource', () {
    blocTest<TranslateCubit, TranslateState>(
      'persists, records recents, clears extras and re-translates',
      setUp: () => mocks.stubTranslate(),
      build: () => mocks.build(),
      seed: () => readyState(input: 'hallo', target: fr).copyWith(
        dictionaryStatus: ExtraStatus.ready,
        dictionary: () => const DictionaryEntry(word: 'hallo'),
      ),
      act: (cubit) {
        cubit.setSource(de);
        expect(cubit.state.source, de);
        expect(cubit.state.dictionary, isNull);
        expect(cubit.state.status, TranslateStatus.translating);
      },
      verify: (_) {
        verify(() => mocks.settings.setLanguages(source: de)).called(1);
        verify(() => mocks.settings.addRecentLanguage(de)).called(1);
        expect(mocks.translateRequests().single.source, de);
      },
    );

    blocTest<TranslateCubit, TranslateState>(
      'does not record auto in recents',
      build: () => mocks.build(),
      seed: () => readyState(source: de),
      act: (cubit) => cubit.setSource(Language.auto),
      verify: (cubit) {
        expect(cubit.state.source, Language.auto);
        verify(() => mocks.settings.setLanguages(source: Language.auto))
            .called(1);
        verifyNever(() => mocks.settings.addRecentLanguage(any()));
        verifyNever(() => mocks.repository.translate(any(), any()));
      },
    );

    blocTest<TranslateCubit, TranslateState>(
      'ignores the current and custom languages',
      build: () => mocks.build(),
      seed: readyState,
      act: (cubit) => cubit
        ..setSource(Language.auto)
        ..setSource(pirate),
      expect: () => <TranslateState>[],
    );
  });

  group('setTarget', () {
    blocTest<TranslateCubit, TranslateState>(
      'persists, records recents and re-translates immediately',
      setUp: () => mocks.stubTranslate(),
      build: () => mocks.build(),
      seed: () => readyState(input: 'hallo'),
      act: (cubit) => cubit.setTarget(fr),
      verify: (cubit) {
        expect(cubit.state.target, fr);
        verify(() => mocks.settings.setLanguages(target: fr)).called(1);
        verify(() => mocks.settings.addRecentLanguage(fr)).called(1);
        expect(mocks.translateRequests().single.target, fr);
      },
    );

    blocTest<TranslateCubit, TranslateState>(
      'accepts custom targets for AI engines',
      build: () => mocks.build(),
      seed: () => readyState(engine: claude),
      act: (cubit) => cubit.setTarget(pirate),
      verify: (cubit) {
        expect(cubit.state.target, pirate);
        expect(cubit.state.canSwap, isFalse);
        verify(() => mocks.settings.addRecentLanguage(pirate)).called(1);
      },
    );

    blocTest<TranslateCubit, TranslateState>(
      'ignores custom targets for Mozhi engines, auto and the current one',
      build: () => mocks.build(),
      seed: readyState,
      act: (cubit) => cubit
        ..setTarget(pirate)
        ..setTarget(Language.auto)
        ..setTarget(en),
      expect: () => <TranslateState>[],
    );
  });

  group('swap', () {
    final hallo = resultOf('Hallo', detected: 'de');

    blocTest<TranslateCubit, TranslateState>(
      'swaps languages and moves the output into the input',
      setUp: () => mocks.stubTranslate(),
      build: () => mocks.build(),
      seed: () => readyState(
        input: 'Hello',
        source: en,
        target: de,
        result: hallo,
        status: TranslateStatus.success,
      ),
      act: (cubit) => cubit.swap(),
      verify: (cubit) {
        expect(cubit.state.source, de);
        expect(cubit.state.target, en);
        expect(cubit.state.input, 'Hallo');
        expect(cubit.state.output, 'Hallo->en');
        verify(() => mocks.settings.setLanguages(source: de, target: en))
            .called(1);
        expect(
          mocks.translateRequests().single,
          const TranslationRequest(text: 'Hallo', source: de, target: en),
        );
      },
    );

    blocTest<TranslateCubit, TranslateState>(
      'uses the detected language when the source is auto',
      setUp: () => mocks.stubTranslate(),
      build: () => mocks.build(),
      seed: () => readyState(
        input: 'Hallo',
        result: resultOf('Hello', detected: 'de'),
        status: TranslateStatus.success,
      ),
      act: (cubit) => cubit.swap(),
      verify: (cubit) {
        expect(cubit.state.source, en);
        expect(cubit.state.target, de);
        expect(cubit.state.input, 'Hello');
      },
    );

    blocTest<TranslateCubit, TranslateState>(
      'keeps languages missing from the other list as they are',
      build: () => mocks.build(),
      seed: () => readyState(
        source: en,
        target: de,
      ).copyWith(sourceLanguages: [Language.auto, en], targetLanguages: [de]),
      act: (cubit) => cubit.swap(),
      verify: (cubit) {
        expect(cubit.state.source, de);
        expect(cubit.state.target, en);
      },
    );

    blocTest<TranslateCubit, TranslateState>(
      'keeps the input and clears the result when there is no output',
      build: () => mocks.build(),
      seed: () => readyState(source: en, target: de),
      act: (cubit) => cubit.swap(),
      expect: () => [readyState(source: de)],
    );

    blocTest<TranslateCubit, TranslateState>(
      'does nothing for auto without a detected language',
      build: () => mocks.build(),
      seed: () => readyState(
        input: 'Hallo',
        result: resultOf('Hello'),
        status: TranslateStatus.success,
      ),
      act: (cubit) => cubit.swap(),
      expect: () => <TranslateState>[],
    );

    blocTest<TranslateCubit, TranslateState>(
      'does nothing when the detected language is not a target',
      build: () => mocks.build(),
      seed: () => readyState(
        input: 'こんにちは',
        result: resultOf('Hello', detected: 'ja'),
        status: TranslateStatus.success,
      ),
      act: (cubit) => cubit.swap(),
      expect: () => <TranslateState>[],
    );

    blocTest<TranslateCubit, TranslateState>(
      'does nothing for custom targets',
      build: () => mocks.build(),
      seed: () => readyState(engine: claude, source: en, target: pirate),
      act: (cubit) => cubit.swap(),
      expect: () => <TranslateState>[],
    );
  });

  group('setOptions', () {
    const formal = TranslationOptions(formality: Formality.more);

    blocTest<TranslateCubit, TranslateState>(
      'persists options without instructions and re-translates AI engines',
      setUp: () => mocks.stubTranslate(),
      build: () => mocks.build(),
      seed: () => readyState(engine: claude, input: 'hello'),
      act: (cubit) => cubit.setOptions(
        const TranslationOptions(
          formality: Formality.more,
          instructions: 'one-off',
        ),
      ),
      verify: (cubit) {
        expect(cubit.state.options, formal);
        verify(() => mocks.settings.setOptions(formal)).called(1);
        expect(mocks.translateRequests().single.options, formal);
      },
    );

    blocTest<TranslateCubit, TranslateState>(
      'does not re-translate Mozhi engines',
      build: () => mocks.build(),
      seed: () => readyState(input: 'hello'),
      act: (cubit) => cubit.setOptions(formal),
      verify: (cubit) {
        expect(cubit.state.options, formal);
        verifyNever(() => mocks.repository.translate(any(), any()));
      },
    );

    blocTest<TranslateCubit, TranslateState>(
      'does not re-translate without input',
      build: () => mocks.build(),
      seed: () => readyState(engine: claude),
      act: (cubit) => cubit.setOptions(formal),
      verify: (_) {
        verifyNever(() => mocks.repository.translate(any(), any()));
      },
    );

    blocTest<TranslateCubit, TranslateState>(
      'ignores unchanged options',
      build: () => mocks.build(),
      seed: () => readyState(engine: claude, input: 'hello', options: formal),
      act: (cubit) => cubit.setOptions(formal),
      expect: () => <TranslateState>[],
      verify: (_) {
        verifyNever(() => mocks.settings.setOptions(any()));
      },
    );
  });

  group('clear', () {
    blocTest<TranslateCubit, TranslateState>(
      'resets input, result and compare entries',
      setUp: () {
        when(() => mocks.repository.translate(any(), any()))
            .thenAnswer((_) => StreamController<TranslationResult>().stream);
      },
      build: () => mocks.build(),
      seed: () =>
          readyState(
            input: 'hello',
            result: resultOf('hallo'),
            status: TranslateStatus.failure,
          ).copyWith(
            error: () => 'x',
            compareEntries: [CompareEntry.success(resultOf('x'))],
            explanation: 'md',
          ),
      act: (cubit) async {
        unawaited(cubit.translate());
        cubit.clear();
      },
      skip: 1,
      expect: () => [readyState()],
    );
  });

  group('applySuggestion', () {
    const suggestion = RefinementSuggestion(
      label: 'Shorter',
      instruction: 'Be brief.',
    );

    blocTest<TranslateCubit, TranslateState>(
      'translates once with the instruction and keeps the options',
      setUp: () => mocks.stubTranslate(),
      build: () => mocks.build(),
      seed: () => readyState(engine: claude, input: 'hello'),
      act: (cubit) => cubit.applySuggestion(suggestion),
      verify: (cubit) {
        final captured = verify(
          () => mocks.repository.translate(captureAny(), captureAny()),
        ).captured;
        expect(captured.first, claude);
        final request = captured.last as TranslationRequest;
        expect(
          request.options.instructions,
          '${TranslateCubit.refinementPrefix} Be brief.',
        );
        expect(cubit.state.options, const TranslationOptions());
      },
    );

    blocTest<TranslateCubit, TranslateState>(
      'uses the assist engine when a Mozhi engine is selected',
      setUp: () => mocks.stubTranslate(),
      build: () => mocks.build(),
      seed: () => readyState(input: 'hello'),
      act: (cubit) => cubit.applySuggestion(suggestion),
      verify: (cubit) {
        verify(() => mocks.repository.translate(claude, any())).called(1);
        expect(cubit.state.result?.engineId, claude.id);
        expect(mocks.historyEntries().single.engineId, claude.id);
      },
    );

    blocTest<TranslateCubit, TranslateState>(
      'falls back to the selected engine without assist engine',
      setUp: () => mocks.stubTranslate(),
      build: () => mocks.build(),
      seed: () => readyState(input: 'hello', assistEngine: null),
      act: (cubit) => cubit.applySuggestion(suggestion),
      verify: (_) {
        verify(() => mocks.repository.translate(google, any())).called(1);
      },
    );
  });

  group('useAlternative', () {
    final original = resultOf('Hallo Welt', detected: 'en');

    blocTest<TranslateCubit, TranslateState>(
      'replaces the output, resets insights and records history',
      build: () => mocks.build(),
      seed: () =>
          readyState(
            input: 'Hello world',
            target: de,
            result: original,
            status: TranslateStatus.success,
          ).copyWith(
            insightsStatus: ExtraStatus.ready,
            insights: const [WordInsight(sourceText: 'a', targetText: 'b')],
            explainStatus: ExtraStatus.ready,
            explanation: 'md',
            alternativesStatus: ExtraStatus.ready,
          ),
      act: (cubit) => cubit.useAlternative('Servus Welt'),
      verify: (cubit) {
        expect(cubit.state.output, 'Servus Welt');
        expect(cubit.state.result?.detectedSource, 'en');
        expect(cubit.state.insights, isEmpty);
        expect(cubit.state.insightsStatus, ExtraStatus.idle);
        expect(cubit.state.explanation, isEmpty);
        expect(cubit.state.alternativesStatus, ExtraStatus.ready);
        final entry = mocks.historyEntries().single;
        expect(entry.translation, 'Servus Welt');
        expect(entry.text, 'Hello world');
        expect(entry.engineId, google.id);
      },
    );

    blocTest<TranslateCubit, TranslateState>(
      'does nothing without a result',
      build: () => mocks.build(),
      seed: () => readyState(input: 'Hello world'),
      act: (cubit) => cubit.useAlternative('x'),
      expect: () => <TranslateState>[],
    );

    blocTest<TranslateCubit, TranslateState>(
      'does nothing for the current text',
      build: () => mocks.build(),
      seed: () => readyState(input: 'Hello world', result: original),
      act: (cubit) => cubit.useAlternative('Hallo Welt'),
      expect: () => <TranslateState>[],
      verify: (_) => verifyNever(() => mocks.history.add(any())),
    );
  });

  group('applyVariation', () {
    const insight = WordInsight(
      sourceText: 'world',
      targetText: 'Welt',
      variations: [Alternative(text: 'Erde')],
    );
    const other = WordInsight(sourceText: 'hello', targetText: 'Hallo');
    final original = resultOf('Hallo Welt, Welt');

    blocTest<TranslateCubit, TranslateState>(
      'replaces the first occurrence and updates the insight',
      build: () => mocks.build(),
      seed: () => readyState(
        input: 'Hello world, world',
        result: original,
        status: TranslateStatus.success,
      ).copyWith(insights: const [other, insight]),
      act: (cubit) => cubit.applyVariation(insight, 'Erde'),
      verify: (cubit) {
        expect(cubit.state.output, 'Hallo Erde, Welt');
        expect(cubit.state.insights.first, same(other));
        final updated = cubit.state.insights.last;
        expect(updated.targetText, 'Erde');
        expect(updated.sourceText, 'world');
        expect(updated.variations, insight.variations);
        expect(mocks.historyEntries().single.translation, 'Hallo Erde, Welt');
      },
    );

    blocTest<TranslateCubit, TranslateState>(
      'does nothing when the span is missing',
      build: () => mocks.build(),
      seed: () => readyState(input: 'x', result: resultOf('Hallo')),
      act: (cubit) => cubit
        ..applyVariation(insight, 'Erde')
        ..applyVariation(
          const WordInsight(sourceText: 'x', targetText: ''),
          'Erde',
        ),
      expect: () => <TranslateState>[],
    );

    blocTest<TranslateCubit, TranslateState>(
      'does nothing without a result',
      build: () => mocks.build(),
      seed: readyState,
      act: (cubit) => cubit.applyVariation(insight, 'Erde'),
      expect: () => <TranslateState>[],
    );
  });

  group('close', () {
    test('cancels the pending debounce', () async {
      mocks.stubTranslate();
      final cubit = mocks.build();
      await cubit.loadEngines();
      cubit.setInput('hello');
      await cubit.close();
      await Future<void>.delayed(afterDebounce);
      verifyNever(() => mocks.repository.translate(any(), any()));
    });
  });
}
