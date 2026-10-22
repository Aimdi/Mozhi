import 'dart:async';

import 'package:bloc_test/bloc_test.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:mocktail/mocktail.dart';
import 'package:mozhi/settings/models/app_settings.dart';
import 'package:mozhi/translate/cubit/translate_cubit.dart';
import 'package:mozhi/usage/usage.dart';
import 'package:translation_repository/translation_repository.dart';

import 'translate_cubit_helpers.dart';

class _MockUsageTracker extends Mock implements UsageTracker;

void main() {
  setUpAll(registerTranslateFallbacks);

  late TranslateMocks mocks;
  final offline = TranslationEngine.offline();
  const sentence = 'The weather is nice today and we go out.';

  TranslationResult suspect(
    TranslationEngine engine, {
    TranslationWarningKind kind = TranslationWarningKind.echo,
  }) => resultOf(
    sentence,
    engine: engine,
  ).copyWith(warnings: [TranslationWarning(kind)]);

  void answer(TranslationEngine engine, Object answer) =>
      when(() => mocks.repository.translate(engine, any())).thenAnswer(
        (_) => answer is TranslationResult
            ? Stream.value(answer)
            : Stream.error(answer),
      );

  void allowWithoutConsent(Set<String> engineIds) =>
      when(
        () => mocks.repository.needsConsent(
          any(),
          source: any(named: 'source'),
          target: any(named: 'target'),
        ),
      ).thenAnswer(
        (invocation) => !engineIds.contains(
          (invocation.positionalArguments.single as TranslationEngine).id,
        ),
      );

  setUp(() {
    mocks = TranslateMocks();
    when(() => mocks.repository.getEngines(refresh: any(named: 'refresh')))
        .thenAnswer((_) async => [google, deepl, claude, deeplApi, offline]);
    allowWithoutConsent({});
  });

  Future<TranslateCubit> ready() async {
    final cubit = mocks.build();
    addTearDown(cubit.close);
    await cubit.loadEngines();
    cubit
      ..setSource(en)
      ..setTarget(de);
    return cubit;
  }

  group('fallback', () {
    test('translates on the device after a suspect result', () async {
      answer(google, suspect(google));
      answer(offline, resultOf('Das Wetter ist schön.', engine: offline));
      final cubit = await ready();
      final states = <TranslateState>[];
      final subscription = cubit.stream.listen(states.add);
      cubit.setInput(sentence);
      await cubit.translate();
      await subscription.cancel();

      expect(cubit.state.result?.text, 'Das Wetter ist schön.');
      expect(cubit.state.status, TranslateStatus.success);
      expect(
        cubit.state.fallback,
        TranslationFallback(
          fromEngineName: 'Google',
          reason: TranslationWarningKind.echo,
          engineName: offline.name,
          onDevice: true,
        ),
      );
      // The suspect result was shown, unfinished, while the device worked.
      expect(
        states.any(
          (s) => s.result?.text == sentence && !(s.result?.isComplete ?? true),
        ),
        isTrue,
      );
      final entry = mocks.historyEntries().single;
      expect(entry.engineId, offline.id);
      expect(entry.translation, 'Das Wetter ist schön.');
      // A new result drops the notice.
      answer(google, resultOf('Hallo'));
      cubit.setInput('Hello');
      await cubit.translate();
      expect(cubit.state.fallback, isNull);
    });

    test('uses engines allowed without consent, never cloud ones', () async {
      allowWithoutConsent({deepl.id, claude.id, deeplApi.id});
      answer(google, suspect(google, kind: TranslationWarningKind.length));
      answer(offline, const OfflineModelMissingException(['de']));
      answer(deepl, resultOf('Das Wetter ist schön.', engine: deepl));
      final cubit = await ready();
      cubit.setInput(sentence);
      await cubit.translate();
      expect(cubit.state.result?.engineId, deepl.id);
      expect(
        cubit.state.fallback,
        const TranslationFallback(
          fromEngineName: 'Google',
          reason: TranslationWarningKind.length,
          engineName: 'DeepL',
          onDevice: false,
        ),
      );
      verifyNever(() => mocks.repository.translate(claude, any()));
      verifyNever(() => mocks.repository.translate(deeplApi, any()));
    });

    test('skips engines that need a new consent', () async {
      when(() => mocks.repository.getEngines(refresh: any(named: 'refresh')))
          .thenAnswer((_) async => [google, deepl]);
      answer(google, suspect(google));
      final cubit = await ready();
      cubit.setInput(sentence);
      await cubit.translate();
      verifyNever(() => mocks.repository.translate(deepl, any()));
      expect(cubit.state.result?.isSuspect, isTrue);
      expect(cubit.state.result?.isComplete, isTrue);
      expect(cubit.state.fallback, isNull);
      expect(cubit.state.status, TranslateStatus.success);
    });

    test('a repository without needsConsent allows only the device', () async {
      reset(mocks.repository);
      mocks = TranslateMocks();
      when(() => mocks.repository.getEngines(refresh: any(named: 'refresh')))
          .thenAnswer((_) async => [google, deepl]);
      answer(google, suspect(google));
      final cubit = await ready();
      cubit.setInput(sentence);
      await cubit.translate();
      verifyNever(() => mocks.repository.translate(deepl, any()));
      expect(cubit.state.result?.isSuspect, isTrue);
    });

    test('keeps the suspect result when no fallback does better', () async {
      allowWithoutConsent({deepl.id});
      answer(
        google,
        suspect(google, kind: TranslationWarningKind.wrongLanguage),
      );
      answer(offline, Exception('no model'));
      answer(deepl, suspect(deepl));
      final cubit = await ready();
      cubit.setInput(sentence);
      await cubit.translate();
      expect(cubit.state.result?.engineId, google.id);
      expect(cubit.state.result?.isComplete, isTrue);
      expect(cubit.state.fallback, isNull);
      verify(() => mocks.repository.translate(deepl, any())).called(1);
    });

    test('moves on when a fallback cannot even start', () async {
      allowWithoutConsent({deepl.id});
      answer(google, suspect(google));
      when(() => mocks.repository.translate(offline, any()))
          .thenThrow(StateError('no'));
      answer(deepl, resultOf('Das Wetter ist schön.', engine: deepl));
      final cubit = await ready();
      cubit.setInput(sentence);
      await cubit.translate();
      expect(cubit.state.result?.engineId, deepl.id);
    });

    test('a fallback that ends without a result moves on', () async {
      allowWithoutConsent({deepl.id});
      answer(google, suspect(google));
      when(() => mocks.repository.translate(offline, any()))
          .thenAnswer((_) => const Stream.empty());
      answer(deepl, resultOf('Das Wetter ist schön.', engine: deepl));
      final cubit = await ready();
      cubit.setInput(sentence);
      await cubit.translate();
      expect(cubit.state.result?.engineId, deepl.id);
    });

    test('good results and errors are not fallen back from', () async {
      answer(google, resultOf('Das Wetter ist schön.'));
      final cubit = await ready();
      cubit.setInput(sentence);
      await cubit.translate();
      verifyNever(() => mocks.repository.translate(offline, any()));
      answer(google, Exception('down'));
      cubit.setInput('$sentence!');
      await cubit.translate();
      expect(cubit.state.status, TranslateStatus.failure);
      verifyNever(() => mocks.repository.translate(offline, any()));
    });

    test('a new input cancels the fallback in flight', () async {
      answer(google, suspect(google));
      final slow = StreamController<TranslationResult>();
      addTearDown(slow.close);
      when(() => mocks.repository.translate(offline, any()))
          .thenAnswer((_) => slow.stream);
      final cubit = await ready();
      cubit.setInput(sentence);
      unawaited(cubit.translate());
      await Future<void>.delayed(Duration.zero);
      await Future<void>.delayed(Duration.zero);
      expect(slow.hasListener, isTrue);
      cubit.setInput('');
      await Future<void>.delayed(Duration.zero);
      expect(slow.hasListener, isFalse);
    });

    test('records the usage of every engine that worked', () async {
      final tracker = _MockUsageTracker();
      when(
        () => tracker.recordText(
          any(),
          input: any(named: 'input'),
          output: any(named: 'output'),
        ),
      ).thenAnswer((_) async => const UsageStats(requests: 1));
      mocks.usageTracker = tracker;
      const localAi = TranslationEngine(
        id: 'ai:local',
        kind: EngineKind.ai,
        name: 'Local',
        providerId: 'local',
        isLocal: true,
      );
      when(() => mocks.repository.getEngines(refresh: any(named: 'refresh')))
          .thenAnswer((_) async => [claude, localAi]);
      answer(
        claude,
        suspect(claude, kind: TranslationWarningKind.notATranslation),
      );
      answer(localAi, resultOf('Das Wetter ist schön.', engine: localAi));
      final cubit = mocks.build();
      addTearDown(cubit.close);
      await cubit.loadEngines();
      await cubit.selectEngine(claude);
      cubit.setInput(sentence);
      await cubit.translate();
      expect(cubit.state.result?.engineId, localAi.id);
      expect(
        cubit.state.fallback?.reason,
        TranslationWarningKind.notATranslation,
      );
      final providers = verify(
        () => tracker.recordText(
          captureAny(),
          input: any(named: 'input'),
          output: any(named: 'output'),
        ),
      ).captured;
      expect(providers, ['claude', 'local']);
    });
  });

  group('debounce', () {
    test('the on-device engine waits less', () {
      final settings = mocks.settings;
      TranslateCubit build({Duration? offlineDebounce, Duration? debounce}) =>
          TranslateCubit(
            repository: mocks.repository,
            settings: settings,
            history: mocks.history,
            debounce: debounce ?? const Duration(milliseconds: 600),
            offlineDebounce: offlineDebounce,
          );
      final standard = build();
      addTearDown(standard.close);
      expect(standard.offlineDebounce, TranslateCubit.defaultOfflineDebounce);
      final quick = build(debounce: const Duration(milliseconds: 100));
      addTearDown(quick.close);
      expect(quick.offlineDebounce, const Duration(milliseconds: 100));
      final custom = build(offlineDebounce: const Duration(milliseconds: 5));
      addTearDown(custom.close);
      expect(custom.offlineDebounce, const Duration(milliseconds: 5));
    });

    blocTest<TranslateCubit, TranslateState>(
      'instant translation on the device starts after offlineDebounce',
      setUp: () {
        when(() => mocks.repository.getEngines(refresh: any(named: 'refresh')))
            .thenAnswer((_) async => [offline, google]);
        mocks.stubTranslate();
      },
      build: () => TranslateCubit(
        repository: mocks.repository,
        settings: mocks.settings,
        history: mocks.history,
        debounce: const Duration(seconds: 5),
        offlineDebounce: const Duration(milliseconds: 10),
      ),
      act: (cubit) async {
        await cubit.loadEngines();
        await cubit.selectEngine(offline);
        cubit.setInput('Hallo');
        await Future<void>.delayed(const Duration(milliseconds: 80));
      },
      verify: (_) =>
          verify(() => mocks.repository.translate(offline, any())).called(1),
    );
  });

  group('personal data shield', () {
    late StreamController<AppSettings> settings;

    setUp(() {
      settings = StreamController<AppSettings>();
      addTearDown(settings.close);
      whenListen(
        mocks.settings,
        settings.stream,
        initialState: const AppSettings(maskPersonalData: false),
      );
    });

    test('is pushed from the first engine load on, when it changes', () async {
      final cubit = mocks.build();
      addTearDown(cubit.close);
      settings.add(const AppSettings(maskPersonalData: false));
      await Future<void>.delayed(Duration.zero);
      verifyNever(() => mocks.repository.maskPersonalData = any());
      await cubit.loadEngines();
      verify(() => mocks.repository.maskPersonalData = false).called(1);
      await cubit.loadEngines();
      settings.add(const AppSettings(maskPersonalData: false));
      await Future<void>.delayed(Duration.zero);
      verifyNever(() => mocks.repository.maskPersonalData = any());
      when(() => mocks.settings.state).thenReturn(const AppSettings());
      settings.add(const AppSettings());
      await Future<void>.delayed(Duration.zero);
      verify(() => mocks.repository.maskPersonalData = true).called(1);
    });

    test('ignores repositories without it', () async {
      when(() => mocks.repository.maskPersonalData = any())
          .thenThrow(UnimplementedError());
      final cubit = mocks.build();
      addTearDown(cubit.close);
      await expectLater(cubit.loadEngines(), completes);
    });
  });
}
