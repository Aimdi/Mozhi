// Temporary review repro file. Each test PASSES when the bug is present.
import 'dart:async';

import 'package:flutter_test/flutter_test.dart';
import 'package:mocktail/mocktail.dart';
import 'package:mozhi/settings/models/app_settings.dart';
import 'package:mozhi/translate/cubit/translate_cubit.dart';
import 'package:translation_repository/translation_repository.dart';

import 'translate_cubit_helpers.dart';

void main() {
  setUpAll(registerTranslateFallbacks);

  late TranslateMocks mocks;
  setUp(() => mocks = TranslateMocks());

  test(
    'R1 saved engine with failing languages locks out all engines',
    () async {
      mocks.stubSettings(const AppSettings(engineId: 'mozhi:deepl'));
      when(() => mocks.repository.getSourceLanguages(deepl))
          .thenAnswer((_) async => throw Exception('deepl down'));
      final cubit = mocks.build();
      await cubit.loadEngines();
      expect(cubit.state.enginesStatus, EnginesStatus.failure);
      expect(cubit.state.engines, isEmpty); // selector hidden -> NoEnginesView
      await cubit.loadEngines(refresh: true); // Retry
      expect(cubit.state.engines, isEmpty);
      expect(cubit.state.engine, isNull);
      await cubit.close();
    },
  );

  test(
    'R1b selectEngine persists a failing engine before languages load',
    () async {
      when(() => mocks.repository.getSourceLanguages(deepl))
          .thenAnswer((_) async => throw Exception('deepl down'));
      final cubit = mocks.build()..emit(readyState());
      await cubit.selectEngine(deepl);
      verify(() => mocks.settings.setEngine('mozhi:deepl')).called(1);
      expect(cubit.state.engine, deepl);
      await cubit.close();
    },
  );

  test(
    'R2 selectEngine during refresh: status stuck loading, list stale',
    () async {
      final slow = Completer<List<TranslationEngine>>();
      when(() => mocks.repository.getEngines(refresh: any(named: 'refresh')))
          .thenAnswer((_) => slow.future);
      final cubit = mocks.build()..emit(readyState());
      final load = cubit.loadEngines(refresh: true);
      await cubit.selectEngine(deepl);
      slow.complete([google, deepl, claude, local]);
      await load;
      expect(cubit.state.enginesStatus, EnginesStatus.loading);
      expect(cubit.state.engines, allEngines); // `local` never appears
      await cubit.close();
    },
  );

  test('R3 swap replaces edited input with the stale output', () async {
    mocks.stubTranslate();
    final cubit = mocks.build()
      ..emit(
        readyState(
          input: 'Hello',
          source: en,
          target: de,
          result: resultOf('Hallo'),
          status: TranslateStatus.success,
        ),
      );
    cubit
      ..setInput('Hello world, how are you?')
      ..swap();
    expect(cubit.state.input, 'Hallo');
    await cubit.close();
  });

  test('R4 useAlternative after editing input records a wrong pair', () async {
    when(
      () => mocks.repository.getAlternatives(
        any(),
        any(),
        any(),
        span: any(named: 'span'),
      ),
    ).thenAnswer(
      (_) async => const AlternativeTranslations(
        description: '',
        alternatives: [Alternative(text: 'Guten Morgen!')],
      ),
    );
    final cubit = mocks.build()
      ..emit(
        readyState(
          engine: claude,
          input: 'Good morning',
          target: de,
          result: resultOf('Guten Morgen', engine: claude),
          status: TranslateStatus.success,
        ),
      );
    cubit.setInput('Good night'); // AI: no instant translate by default
    await cubit.loadAlternatives();
    final request = verify(
      () => mocks.repository.getAlternatives(
        any(),
        captureAny(),
        captureAny(),
        span: any(named: 'span'),
      ),
    ).captured;
    expect((request[0] as TranslationRequest).text, 'Good night');
    expect(request[1], 'Guten Morgen');
    cubit.useAlternative('Guten Morgen!');
    final entry = mocks.historyEntries().single;
    expect(entry.text, 'Good night');
    expect(entry.translation, 'Guten Morgen!');
    await cubit.close();
  });

  test('R5 applyVariation replaces a substring inside another word', () async {
    const insight = WordInsight(sourceText: 'the', targetText: 'die');
    final cubit = mocks.build()
      ..emit(
        readyState(
          input: 'The study shows that the world',
          result: resultOf('Die Studie zeigt, dass die Welt'),
          status: TranslateStatus.success,
        ).copyWith(insights: const [insight]),
      );
    cubit.applyVariation(insight, 'jene');
    expect(cubit.state.output, 'Die Stujene zeigt, dass die Welt');
    await cubit.close();
  });

  test('R6 instant translate records every debounced prefix', () async {
    mocks.stubTranslate();
    final cubit = mocks.build()..emit(readyState(target: de));
    cubit.setInput('Hello');
    await Future<void>.delayed(afterDebounce);
    cubit.setInput('Hello wor');
    await Future<void>.delayed(afterDebounce);
    cubit.setInput('Hello world');
    await Future<void>.delayed(afterDebounce);
    expect(mocks.historyEntries().map((e) => e.text), [
      'Hello',
      'Hello wor',
      'Hello world',
    ]);
    await cubit.close();
  });

  test('R7 refresh auto-translates with instantTranslateAi off', () async {
    mocks
      ..stubTranslate()
      ..stubSettings(const AppSettings(engineId: 'ai:claude'));
    final cubit = mocks.build()
      ..emit(readyState(engine: claude, input: 'A long document'));
    cubit.setInput('A long document, edited');
    await Future<void>.delayed(afterDebounce);
    verifyNever(() => mocks.repository.translate(any(), any()));
    await cubit.loadEngines(refresh: true); // provider settings edited
    await Future<void>.delayed(Duration.zero);
    verify(() => mocks.repository.translate(claude, any())).called(1);
    await cubit.close();
  });

  test('R7b refresh in compare mode runs a full compare', () async {
    when(() => mocks.repository.compare(any(), any()))
        .thenAnswer((_) => const Stream.empty());
    final cubit = mocks.build()
      ..emit(readyState(input: 'text').copyWith(compareMode: true));
    await cubit.loadEngines(refresh: true);
    await Future<void>.delayed(Duration.zero);
    verify(() => mocks.repository.compare(any(), any())).called(1);
    await cubit.close();
  });

  test('R8 explicitly picked target is reverted by smart swap', () async {
    when(() => mocks.repository.translate(any(), any())).thenAnswer((inv) {
      final r = inv.positionalArguments[1] as TranslationRequest;
      return Stream.value(resultOf('x->${r.target.code}', detected: 'en'));
    });
    mocks.stubSettings(const AppSettings(recentLanguages: [de]));
    final cubit = mocks.build()
      ..emit(readyState(engine: claude, input: 'gonna be late', target: de));
    cubit.setTarget(en); // e.g. rewrite English formally
    await Future<void>.delayed(afterDebounce);
    expect(cubit.state.target, de);
    await cubit.close();
  });

  test('R9 engine round trip loses the custom target', () async {
    final cubit = mocks.build()
      ..emit(readyState(engine: claude, target: pirate));
    await cubit.selectEngine(google);
    expect(cubit.state.target, en);
    await cubit.selectEngine(claude);
    expect(cubit.state.target, en);
    await cubit.close();
  });

  test('R10 useAlternative of a span replaces the whole output', () async {
    when(
      () => mocks.repository.getAlternatives(
        any(),
        any(),
        any(),
        span: any(named: 'span'),
      ),
    ).thenAnswer(
      (_) async => const AlternativeTranslations(
        description: '',
        alternatives: [Alternative(text: 'Erde')],
      ),
    );
    final cubit = mocks.build()
      ..emit(
        readyState(
          input: 'Hello world',
          result: resultOf('Hallo Welt'),
          status: TranslateStatus.success,
        ),
      );
    await cubit.loadAlternatives(span: 'Welt');
    cubit.useAlternative('Erde');
    expect(cubit.state.output, 'Erde');
    await cubit.close();
  });

  test('R11 toggling compare during debounce auto-runs compare', () async {
    mocks.stubTranslate();
    when(() => mocks.repository.compare(any(), any()))
        .thenAnswer((_) => const Stream.empty());
    final cubit = mocks.build()..emit(readyState());
    cubit
      ..setInput('hello')
      ..setCompareMode(enabled: true);
    await Future<void>.delayed(afterDebounce);
    verify(() => mocks.repository.compare(allEngines, any())).called(1);
    await cubit.close();
  });

  test(
    'R12 enginesStatus stays failure after a later successful switch',
    () async {
      mocks.stubTranslate();
      when(() => mocks.repository.getSourceLanguages(deepl))
          .thenAnswer((_) async => throw Exception('x'));
      final cubit = mocks.build()..emit(readyState(input: 'hi'));
      await cubit.selectEngine(deepl);
      await cubit.selectEngine(claude);
      expect(cubit.state.engine, claude);
      expect(cubit.state.enginesStatus, EnginesStatus.failure);
      await cubit.close();
    },
  );

  test('R13 in-flight stale result lands after the input was edited', () async {
    final controller = StreamController<TranslationResult>();
    when(() => mocks.repository.translate(any(), any()))
        .thenAnswer((_) => controller.stream);
    final cubit = mocks.build()
      ..emit(readyState(engine: claude, input: 'Hello', target: de));
    unawaited(cubit.translate());
    cubit.setInput('Goodbye');
    controller.add(resultOf('Hallo', engine: claude));
    await controller.close();
    await Future<void>.delayed(Duration.zero);
    expect(cubit.state.input, 'Goodbye');
    expect(cubit.state.output, 'Hallo');
    expect(cubit.state.status, TranslateStatus.success);
    await cubit.close();
  });

  test('R14 first-run English text swaps target to the first catalogue entry',
      () async {
    when(() => mocks.repository.translate(any(), any())).thenAnswer((inv) {
      final r = inv.positionalArguments[1] as TranslationRequest;
      return Stream.value(resultOf('x->${r.target.code}', detected: 'en'));
    });
    final cubit = mocks.build()
      ..emit(
        readyState(engine: claude, input: 'Hello there').copyWith(
          targetLanguages: LanguageCatalog.all,
        ),
      );
    await cubit.translate();
    expect(cubit.state.target.code, 'ab');
    verify(() => mocks.settings.setLanguages(target: any(named: 'target')))
        .called(1);
    await cubit.close();
  });

  test('R15 selectEngine in compare mode re-runs a full compare', () async {
    when(() => mocks.repository.compare(any(), any()))
        .thenAnswer((_) => const Stream.empty());
    final cubit = mocks.build()
      ..emit(readyState(input: 'text').copyWith(compareMode: true));
    await cubit.selectEngine(deepl);
    verify(() => mocks.repository.compare(allEngines, any())).called(1);
    await cubit.close();
  });
}
