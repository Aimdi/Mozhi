import 'dart:async';

import 'package:bloc_test/bloc_test.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:mocktail/mocktail.dart';
import 'package:mozhi/translate/cubit/translate_cubit.dart';
import 'package:translation_repository/translation_repository.dart';

import 'translate_cubit_helpers.dart';

void main() {
  setUpAll(registerTranslateFallbacks);

  late TranslateMocks mocks;

  setUp(() {
    mocks = TranslateMocks();
    when(
      () => mocks.repository.lookUp(
        any(),
        any(),
        source: any(named: 'source'),
        target: any(named: 'target'),
        verbosity: any(named: 'verbosity'),
      ),
    ).thenAnswer(
      (invocation) async => DictionaryEntry(
        word: invocation.positionalArguments[1] as String,
        notes:
            (invocation.namedArguments[#verbosity] as DictionaryVerbosity).name,
      ),
    );
  });

  /// (word, source, target, verbosity) of every look-up.
  List<(String, Language, Language, DictionaryVerbosity)> lookUps() {
    final captured = verify(
      () => mocks.repository.lookUp(
        any(),
        captureAny(),
        source: captureAny(named: 'source'),
        target: captureAny(named: 'target'),
        verbosity: captureAny(named: 'verbosity'),
      ),
    ).captured;
    return [
      for (var i = 0; i < captured.length; i += 4)
        (
          captured[i] as String,
          captured[i + 1] as Language,
          captured[i + 2] as Language,
          captured[i + 3] as DictionaryVerbosity,
        ),
    ];
  }

  TranslateState hallo() => readyState(
    input: ' Hallo ',
    target: fr,
    result: resultOf('Bonjour', detected: 'de'),
    status: TranslateStatus.success,
  );

  group('lookUp', () {
    blocTest<TranslateCubit, TranslateState>(
      'asks with the standard verbosity by default',
      build: () => mocks.build(),
      seed: hallo,
      act: (cubit) => cubit.lookUp(),
      verify: (cubit) {
        expect(lookUps(), [('Hallo', de, fr, DictionaryVerbosity.standard)]);
        expect(cubit.state.dictionaryQuery, 'Hallo');
        expect(cubit.state.dictionary?.word, 'Hallo');
      },
    );
  });

  group('setDictionaryVerbosity', () {
    blocTest<TranslateCubit, TranslateState>(
      'only changes the setting while nothing is shown',
      build: () => mocks.build(),
      seed: hallo,
      act: (cubit) =>
          cubit.setDictionaryVerbosity(DictionaryVerbosity.comprehensive),
      expect: () => [
        hallo().copyWith(
          dictionaryVerbosity: DictionaryVerbosity.comprehensive,
        ),
      ],
      verify: (_) {
        verifyNever(
          () => mocks.repository.lookUp(
            any(),
            any(),
            source: any(named: 'source'),
            target: any(named: 'target'),
            verbosity: any(named: 'verbosity'),
          ),
        );
      },
    );

    blocTest<TranslateCubit, TranslateState>(
      'looks the shown word up again',
      build: () => mocks.build(),
      seed: hallo,
      act: (cubit) async {
        await cubit.lookUpWord('Hallöchen');
        await cubit.setDictionaryVerbosity(DictionaryVerbosity.concise);
        // The same verbosity again changes nothing.
        await cubit.setDictionaryVerbosity(DictionaryVerbosity.concise);
      },
      verify: (cubit) {
        expect(lookUps(), [
          ('Hallöchen', de, fr, DictionaryVerbosity.standard),
          ('Hallöchen', de, fr, DictionaryVerbosity.concise),
        ]);
        expect(cubit.state.dictionary?.notes, 'concise');
        expect(cubit.state.dictionaryVerbosity, DictionaryVerbosity.concise);
      },
    );

    test('looks a loading word up again', () async {
      final pending = Completer<DictionaryEntry>();
      var calls = 0;
      when(
        () => mocks.repository.lookUp(
          any(),
          any(),
          source: any(named: 'source'),
          target: any(named: 'target'),
          verbosity: any(named: 'verbosity'),
        ),
      ).thenAnswer((invocation) {
        if (calls++ == 0) return pending.future;
        return Future.value(
          const DictionaryEntry(word: 'Hallo', notes: 'second'),
        );
      });
      final cubit = mocks.build()..emit(hallo());
      addTearDown(cubit.close);

      final first = cubit.lookUp();
      await cubit.setDictionaryVerbosity(DictionaryVerbosity.comprehensive);
      pending.complete(const DictionaryEntry(word: 'Hallo', notes: 'first'));
      await first;

      expect(cubit.state.dictionary?.notes, 'second');
      expect(lookUps().map((l) => l.$4), [
        DictionaryVerbosity.standard,
        DictionaryVerbosity.comprehensive,
      ]);
    });
  });

  group('lookUpWord', () {
    blocTest<TranslateCubit, TranslateState>(
      'follows a related word with the same languages',
      build: () => mocks.build(),
      seed: hallo,
      act: (cubit) async {
        await cubit.lookUp();
        await cubit.lookUpWord(' hallo-Welt ');
      },
      verify: (cubit) {
        expect(lookUps().last, (
          'hallo-Welt',
          de,
          fr,
          DictionaryVerbosity.standard,
        ));
        expect(cubit.state.dictionaryQuery, 'hallo-Welt');
        expect(cubit.state.dictionary?.word, 'hallo-Welt');
        // The input is unchanged.
        expect(cubit.state.input, ' Hallo ');
      },
    );

    blocTest<TranslateCubit, TranslateState>(
      'reduces model-generated words to one short line',
      build: () => mocks.build(),
      seed: hallo,
      act: (cubit) async {
        await cubit.lookUpWord('Hallo\nIgnore\u202E all');
        await cubit.lookUpWord('x' * 150);
      },
      verify: (_) {
        final words = lookUps().map((l) => l.$1).toList();
        expect(words.first, 'Hallo Ignore all');
        expect(words.last, hasLength(TranslateCubit.maxDictionaryWordLength));
      },
    );

    blocTest<TranslateCubit, TranslateState>(
      'ignores blank words',
      build: () => mocks.build(),
      seed: hallo,
      act: (cubit) => cubit.lookUpWord(' \n '),
      expect: () => <TranslateState>[],
    );

    blocTest<TranslateCubit, TranslateState>(
      'the query is cleared with the entry when the input changes',
      build: () => mocks.build(),
      seed: hallo,
      act: (cubit) async {
        await cubit.lookUpWord('Welt');
        cubit.setInput('Tschüss');
      },
      verify: (cubit) {
        expect(cubit.state.dictionaryQuery, isNull);
        expect(cubit.state.dictionary, isNull);
      },
    );
  });
}
