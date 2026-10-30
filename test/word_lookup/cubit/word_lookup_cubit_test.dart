import 'dart:async';

import 'package:bloc_test/bloc_test.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:mocktail/mocktail.dart';
import 'package:mozhi/word_lookup/cubit/word_lookup_cubit.dart';
import 'package:translation_repository/translation_repository.dart';

import '../helpers.dart';

const _consent = ConsentRequiredException(
  kind: ConsentKind.cloudProvider,
  destination: CloudProviderDestination('OpenAI'),
  engineId: 'openai:gpt',
);

void main() {
  late MockWordLookupService service;

  setUpAll(() {
    registerFallbackValue(english);
    registerFallbackValue(aiEngine);
  });

  setUp(() {
    service = MockWordLookupService();
    when(() => service.hasDictionaryFor(any())).thenAnswer((_) async => true);
    when(
      () => service.lookUpOffline(
        any(),
        language: any(named: 'language'),
        into: any(named: 'into'),
      ),
    ).thenAnswer((_) async => gatoAnswer);
    when(
      () => service.lookUpOnline(
        any(),
        any(),
        language: any(named: 'language'),
        into: any(named: 'into'),
        sentence: any(named: 'sentence'),
        uiLanguage: any(named: 'uiLanguage'),
      ),
    ).thenAnswer((_) async => aiGatoEntry);
  });

  WordLookupCubit build({
    String word = 'gato',
    Language language = spanish,
    Language? into = english,
    String sentence = 'El gato duerme.',
    TranslationEngine? engine = aiEngine,
  }) => WordLookupCubit(
    service: service,
    word: word,
    language: language,
    into: into,
    sentence: sentence,
    engine: engine,
    uiLanguage: 'German',
  );

  const loading = WordLookupState(
    word: 'gato',
    language: spanish,
    into: english,
    sentence: 'El gato duerme.',
    engine: aiEngine,
  );

  group('WordLookupCubit', () {
    test('starts loading, with a clean word and usable languages', () {
      final cubit = WordLookupCubit(
        service: service,
        word: '  ga\u202Eto\n',
        language: spanish,
        into: Language.auto,
        engine: const TranslationEngine(
          id: 'mozhi:google',
          kind: EngineKind.mozhi,
          name: 'Google',
        ),
      );
      expect(cubit.state.word, 'ga to');
      expect(cubit.state.into, isNull);
      expect(cubit.state.engine, isNull);
      expect(cubit.state.status, WordLookupStatus.loading);
      expect(cubit.state.canLookUpOnline, isFalse);
    });

    test('cuts long words and sentences', () {
      final cubit = build(word: 'a' * 150, sentence: 'b' * 500);
      expect(cubit.state.word.length, WordLookupCubit.maxWordLength);
      expect(cubit.state.sentence.length, WordLookupCubit.maxSentenceLength);
      final emoji = WordLookupCubit.clean('${'a' * 99}😀');
      expect(emoji, 'a' * 99);
    });

    blocTest<WordLookupCubit, WordLookupState>(
      'an offline hit shows the entry',
      build: build,
      act: (cubit) => cubit.load(),
      expect: () => [
        loading,
        loading.copyWith(
          status: WordLookupStatus.found,
          offlineAnswer: () => gatoAnswer,
        ),
      ],
      verify: (cubit) {
        expect(cubit.state.entry, gatoEntry);
        expect(cubit.state.isOnlineEntry, isFalse);
        expect(cubit.state.canLookUpOnline, isTrue);
        verify(
          () => service.lookUpOffline('gato', language: spanish, into: english),
        ).called(1);
        verifyNever(
          () => service.lookUpOnline(
            any(),
            any(),
            language: any(named: 'language'),
            into: any(named: 'into'),
            sentence: any(named: 'sentence'),
            uiLanguage: any(named: 'uiLanguage'),
          ),
        );
      },
    );

    blocTest<WordLookupCubit, WordLookupState>(
      'a miss says so and never asks the engine on its own',
      setUp: () => when(
        () => service.lookUpOffline(
          any(),
          language: any(named: 'language'),
          into: any(named: 'into'),
        ),
      ).thenAnswer((_) async => null),
      build: build,
      act: (cubit) => cubit.load(),
      expect: () => [
        loading,
        loading.copyWith(status: WordLookupStatus.notFound),
      ],
      verify: (cubit) {
        expect(cubit.state.canLookUpOnline, isTrue);
        verifyNever(
          () => service.lookUpOnline(
            any(),
            any(),
            language: any(named: 'language'),
            into: any(named: 'into'),
            sentence: any(named: 'sentence'),
            uiLanguage: any(named: 'uiLanguage'),
          ),
        );
      },
    );

    blocTest<WordLookupCubit, WordLookupState>(
      'a miss, then an explicit look-up with the engine',
      setUp: () => when(
        () => service.lookUpOffline(
          any(),
          language: any(named: 'language'),
          into: any(named: 'into'),
        ),
      ).thenAnswer((_) async => null),
      build: build,
      act: (cubit) async {
        await cubit.load();
        await cubit.lookUpOnline();
      },
      expect: () => [
        loading,
        loading.copyWith(status: WordLookupStatus.notFound),
        loading.copyWith(
          status: WordLookupStatus.notFound,
          onlineStatus: WordLookupOnlineStatus.loading,
        ),
        loading.copyWith(
          status: WordLookupStatus.notFound,
          onlineStatus: WordLookupOnlineStatus.done,
          onlineEntry: () => aiGatoEntry,
        ),
      ],
      verify: (cubit) {
        expect(cubit.state.entry, aiGatoEntry);
        expect(cubit.state.isOnlineEntry, isTrue);
        expect(cubit.state.canLookUpOnline, isFalse);
        verify(
          () => service.lookUpOnline(
            aiEngine,
            'gato',
            language: spanish,
            into: english,
            sentence: 'El gato duerme.',
            uiLanguage: 'German',
          ),
        ).called(1);
      },
    );

    blocTest<WordLookupCubit, WordLookupState>(
      'the engine gets English translations without the other language',
      build: () => build(into: null),
      act: (cubit) => cubit.lookUpOnline(),
      verify: (_) => verify(
        () => service.lookUpOnline(
          aiEngine,
          'gato',
          language: spanish,
          into: english,
          sentence: 'El gato duerme.',
          uiLanguage: 'German',
        ),
      ).called(1),
    );

    blocTest<WordLookupCubit, WordLookupState>(
      'the privacy settings stop the look-up: the error, then a retry',
      setUp: () {
        var calls = 0;
        when(
          () => service.lookUpOnline(
            any(),
            any(),
            language: any(named: 'language'),
            into: any(named: 'into'),
            sentence: any(named: 'sentence'),
            uiLanguage: any(named: 'uiLanguage'),
          ),
        ).thenAnswer((_) async {
          if (calls++ == 0) throw _consent;
          return aiGatoEntry;
        });
      },
      build: build,
      act: (cubit) async {
        await cubit.load();
        await cubit.lookUpOnline();
        expect(cubit.state.onlineStatus, WordLookupOnlineStatus.failure);
        expect(cubit.state.error, _consent);
        expect(cubit.state.canLookUpOnline, isTrue);
        // The offline entry stays.
        expect(cubit.state.entry, gatoEntry);
        await cubit.lookUpOnline();
      },
      skip: 4,
      expect: () => [
        loading.copyWith(
          status: WordLookupStatus.found,
          offlineAnswer: () => gatoAnswer,
          onlineStatus: WordLookupOnlineStatus.loading,
        ),
        loading.copyWith(
          status: WordLookupStatus.found,
          offlineAnswer: () => gatoAnswer,
          onlineStatus: WordLookupOnlineStatus.done,
          onlineEntry: () => aiGatoEntry,
        ),
      ],
      errors: () => [_consent],
    );

    blocTest<WordLookupCubit, WordLookupState>(
      'no dictionary of the language: says so without looking it up',
      setUp: () =>
          when(() => service.hasDictionaryFor(any()))
              .thenAnswer((_) async => false),
      build: build,
      act: (cubit) => cubit.load(),
      expect: () => [
        loading,
        loading.copyWith(status: WordLookupStatus.noDictionary),
      ],
      verify: (_) => verifyNever(
        () => service.lookUpOffline(
          any(),
          language: any(named: 'language'),
          into: any(named: 'into'),
        ),
      ),
    );

    blocTest<WordLookupCubit, WordLookupState>(
      'a failing dictionary reads as not having the word',
      setUp: () => when(
        () => service.lookUpOffline(
          any(),
          language: any(named: 'language'),
          into: any(named: 'into'),
        ),
      ).thenThrow(StateError('broken')),
      build: build,
      act: (cubit) => cubit.load(),
      expect: () => [
        loading,
        loading.copyWith(status: WordLookupStatus.notFound),
      ],
      errors: () => [isStateError],
    );

    blocTest<WordLookupCubit, WordLookupState>(
      'a blank word is not looked up',
      build: () => build(word: '  '),
      act: (cubit) => cubit.load(),
      expect: () => [
        const WordLookupState(
          word: '',
          language: spanish,
          into: english,
          sentence: 'El gato duerme.',
          engine: aiEngine,
        ),
        const WordLookupState(
          word: '',
          language: spanish,
          into: english,
          sentence: 'El gato duerme.',
          engine: aiEngine,
          status: WordLookupStatus.notFound,
        ),
      ],
      verify: (_) => verifyNever(() => service.hasDictionaryFor(any())),
    );

    blocTest<WordLookupCubit, WordLookupState>(
      'without an engine nothing is asked online',
      build: () => build(engine: null),
      act: (cubit) => cubit.lookUpOnline(),
      expect: () => <WordLookupState>[],
    );

    blocTest<WordLookupCubit, WordLookupState>(
      'lookUpWord shows another word, looked up offline',
      build: build,
      act: (cubit) async {
        await cubit.load();
        await cubit.lookUpWord('  ');
        await cubit.lookUpWord('gatear');
      },
      skip: 2,
      expect: () => [
        loading.copyWith(
          word: 'gatear',
          status: WordLookupStatus.found,
          offlineAnswer: () => gatoAnswer,
        ),
        loading.copyWith(word: 'gatear'),
        loading.copyWith(
          word: 'gatear',
          status: WordLookupStatus.found,
          offlineAnswer: () => gatoAnswer,
        ),
      ],
    );

    test('a stale offline answer is ignored', () async {
      final gate = Completer<bool>();
      when(() => service.hasDictionaryFor(any()))
          .thenAnswer((_) => gate.future);
      final cubit = build();
      final first = cubit.load();
      unawaited(cubit.lookUpWord('perro'));
      gate.complete(true);
      await first;
      await pumpEventQueue();
      expect(cubit.state.word, 'perro');
      expect(cubit.state.status, WordLookupStatus.found);
      await cubit.close();
    });

    test('an answer after close is dropped', () async {
      final gate = Completer<DictionaryEntry>();
      when(
        () => service.lookUpOnline(
          any(),
          any(),
          language: any(named: 'language'),
          into: any(named: 'into'),
          sentence: any(named: 'sentence'),
          uiLanguage: any(named: 'uiLanguage'),
        ),
      ).thenAnswer((_) => gate.future);
      final cubit = build();
      final asked = cubit.lookUpOnline();
      await cubit.close();
      gate.complete(aiGatoEntry);
      await asked;
      expect(cubit.state.onlineStatus, WordLookupOnlineStatus.loading);
    });
  });

  group('WordLookupState', () {
    test('an entry with nothing to show is empty', () {
      const empty = WordLookupState(
        word: 'x',
        language: spanish,
        status: WordLookupStatus.found,
        offlineAnswer: OfflineDictionaryAnswer(
          entry: DictionaryEntry(word: 'x'),
          language: 'es',
          attribution: wiktionary,
        ),
      );
      expect(empty.isEmptyEntry, isTrue);
      expect(loading.isEmptyEntry, isTrue);
      expect(
        loading.copyWith(offlineAnswer: () => gatoAnswer).isEmptyEntry,
        isFalse,
      );
    });
  });
}
