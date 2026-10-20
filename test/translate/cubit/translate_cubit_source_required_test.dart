// The engine cannot detect the source language (a short text with "Detect
// language" on the offline engine): the error reaches the state as is, and
// choosing the language translates again.
import 'package:bloc_test/bloc_test.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:mocktail/mocktail.dart';
import 'package:mozhi/translate/cubit/translate_cubit.dart';
import 'package:translation_repository/translation_repository.dart';

import 'translate_cubit_helpers.dart';

const _offline = TranslationEngine(
  id: 'offline:bergamot',
  kind: EngineKind.offline,
  name: 'On this device',
  isLocal: true,
);

const _sourceRequired = SourceLanguageRequiredException(
  engineId: 'offline:bergamot',
);

TranslateState _offlineState({
  String input = 'Hi',
  Language source = Language.auto,
  Language target = en,
  TranslateStatus status = TranslateStatus.idle,
}) => readyState(
  engine: _offline,
  assistEngine: null,
  engines: const [_offline, google],
  input: input,
  source: source,
  target: target,
  status: status,
);

void main() {
  setUpAll(registerTranslateFallbacks);

  late TranslateMocks mocks;

  setUp(() {
    mocks = TranslateMocks();
  });

  group('SourceLanguageRequiredException', () {
    blocTest<TranslateCubit, TranslateState>(
      'reaches the state unwrapped as the failure',
      setUp: () {
        when(() => mocks.repository.translate(any(), any()))
            .thenAnswer((_) => Stream.error(_sourceRequired));
      },
      build: () => mocks.build(),
      seed: _offlineState,
      act: (cubit) => cubit.translate(),
      expect: () => [
        _offlineState(status: TranslateStatus.translating),
        _offlineState(status: TranslateStatus.failure)
            .copyWith(error: () => _sourceRequired),
      ],
      verify: (cubit) {
        expect(cubit.state.error, same(_sourceRequired));
        expect(cubit.state.consent, isNull);
      },
    );

    blocTest<TranslateCubit, TranslateState>(
      'choosing the source language translates again from it',
      setUp: () {
        when(() => mocks.repository.translate(any(), any()))
            .thenAnswer((invocation) {
              final request =
                  invocation.positionalArguments[1] as TranslationRequest;
              if (request.source.isAuto) return Stream.error(_sourceRequired);
              return Stream.value(resultOf('Hallo', engine: _offline));
            });
      },
      build: () => mocks.build(),
      seed: _offlineState,
      act: (cubit) async {
        await cubit.translate();
        cubit.setSource(de);
        await Future<void>.delayed(Duration.zero);
      },
      verify: (cubit) {
        expect(cubit.state.source, de);
        expect(cubit.state.status, TranslateStatus.success);
        expect(cubit.state.error, isNull);
        expect(cubit.state.output, 'Hallo');
        expect(mocks.translateRequests().map((r) => r.source), [
          Language.auto,
          de,
        ]);
        verify(() => mocks.settings.setLanguages(source: de)).called(1);
      },
    );
  });

  group('recentSourceSuggestion', () {
    test('is the most recent source the engine lists, as it lists it', () {
      const german = Language(code: 'de-DE', name: 'German (Germany)');
      final state = _offlineState();
      expect(
        state.recentSourceSuggestion(const [
          LanguagePair(source: Language.auto, target: en),
          LanguagePair(source: pirate, target: en),
          LanguagePair(source: german, target: en),
          LanguagePair(source: fr, target: en),
        ]),
        de,
      );
    });

    test('skips the target and languages the engine does not list', () {
      final state = _offlineState(target: fr);
      expect(
        state.recentSourceSuggestion(const [
          LanguagePair(source: ja, target: en),
          LanguagePair(source: fr, target: en),
          LanguagePair(source: es, target: fr),
        ]),
        es,
      );
    });

    test('is null without a fitting recent source', () {
      expect(_offlineState().recentSourceSuggestion(const []), isNull);
      expect(
        _offlineState().recentSourceSuggestion(const [
          LanguagePair(source: en, target: de),
          LanguagePair(source: ja, target: en),
        ]),
        isNull,
      );
    });

    test('is null when the source is not auto', () {
      expect(
        _offlineState(
          source: fr,
        ).recentSourceSuggestion(const [LanguagePair(source: de, target: en)]),
        isNull,
      );
    });

    test('takes any recent source with a custom target', () {
      expect(
        _offlineState(target: pirate).recentSourceSuggestion(const [
          LanguagePair(source: de, target: pirate),
        ]),
        de,
      );
    });
  });
}
