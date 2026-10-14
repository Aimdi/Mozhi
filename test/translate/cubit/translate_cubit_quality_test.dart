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

  /// Google normally, DeepL as "Fast", Claude as "Best".
  const configured = AppSettings(
    engineId: 'mozhi:google',
    fastEngineId: 'mozhi:deepl',
    bestEngineId: 'ai:claude',
  );

  /// Loaded state with the quality engines resolved.
  TranslateState ready({
    TranslationEngine engine = google,
    QualityMode mode = QualityMode.off,
    String input = '',
  }) => readyState(engine: engine, input: input).copyWith(
    qualityMode: mode,
    fastEngine: () => deepl,
    bestEngine: () => claude,
  );

  group('loadEngines', () {
    blocTest<TranslateCubit, TranslateState>(
      'resolves the quality mode engines',
      setUp: () => mocks.stubSettings(configured),
      build: () => mocks.build(),
      act: (cubit) => cubit.loadEngines(),
      verify: (cubit) {
        final state = cubit.state;
        expect(state.engine, google);
        expect(state.qualityMode, QualityMode.off);
        expect(state.fastEngine, deepl);
        expect(state.bestEngine, claude);
        expect(state.hasQualityModes, isTrue);
        expect(state.availableQualityModes, QualityMode.values);
        expect(state.qualityEngine(QualityMode.best), claude);
        expect(state.qualityEngine(QualityMode.off), isNull);
      },
    );

    blocTest<TranslateCubit, TranslateState>(
      'applies the saved mode without changing the normal engine',
      setUp: () => mocks.stubSettings(
        configured.copyWith(qualityMode: QualityMode.best),
      ),
      build: () => mocks.build(),
      act: (cubit) => cubit.loadEngines(),
      verify: (cubit) {
        expect(cubit.state.engine, claude);
        expect(cubit.state.qualityMode, QualityMode.best);
        verifyNever(() => mocks.settings.setEngine(any()));
      },
    );

    blocTest<TranslateCubit, TranslateState>(
      'uses the normal engine when the mode engine is unavailable',
      setUp: () => mocks.stubSettings(
        configured.copyWith(
          bestEngineId: () => 'ai:gone',
          qualityMode: QualityMode.best,
        ),
      ),
      build: () => mocks.build(),
      act: (cubit) => cubit.loadEngines(),
      verify: (cubit) {
        expect(cubit.state.engine, google);
        expect(cubit.state.qualityMode, QualityMode.off);
        expect(cubit.state.bestEngine, isNull);
        expect(cubit.state.availableQualityModes, [
          QualityMode.off,
          QualityMode.fast,
        ]);
        // The saved mode is kept for when the engine comes back.
        verifyNever(() => mocks.settings.setQualityMode(any()));
      },
    );

    final down = Exception('claude down');

    blocTest<TranslateCubit, TranslateState>(
      'uses the normal engine when the mode engine fails to load',
      setUp: () {
        mocks.stubSettings(configured.copyWith(qualityMode: QualityMode.best));
        when(() => mocks.repository.getSourceLanguages(claude)).thenThrow(down);
      },
      build: () => mocks.build(),
      act: (cubit) => cubit.loadEngines(),
      errors: () => [down],
      verify: (cubit) {
        expect(cubit.state.engine, google);
        expect(cubit.state.qualityMode, QualityMode.off);
      },
    );

    blocTest<TranslateCubit, TranslateState>(
      'keeps the mode when every engine fails to load',
      setUp: () {
        mocks.stubSettings(configured.copyWith(qualityMode: QualityMode.best));
        when(() => mocks.repository.getSourceLanguages(any())).thenThrow(down);
      },
      build: () => mocks.build(),
      act: (cubit) => cubit.loadEngines(),
      errors: () => [down, down],
      verify: (cubit) {
        expect(cubit.state.enginesStatus, EnginesStatus.failure);
        expect(cubit.state.engine, claude);
        expect(cubit.state.qualityMode, QualityMode.best);
        expect(cubit.state.fastEngine, deepl);
      },
    );

    blocTest<TranslateCubit, TranslateState>(
      'clears the modes without engines',
      setUp: () {
        mocks.stubSettings(configured);
        when(() => mocks.repository.getEngines(refresh: any(named: 'refresh')))
            .thenAnswer((_) async => const []);
      },
      build: () => mocks.build(),
      seed: () => ready(mode: QualityMode.best, engine: claude),
      act: (cubit) => cubit.loadEngines(),
      verify: (cubit) {
        expect(cubit.state.qualityMode, QualityMode.off);
        expect(cubit.state.hasQualityModes, isFalse);
        expect(cubit.state.availableQualityModes, [QualityMode.off]);
      },
    );

    blocTest<TranslateCubit, TranslateState>(
      'a mode picked during a refresh is not saved as the normal engine',
      setUp: () {
        var settings = configured;
        when(() => mocks.settings.state).thenAnswer((_) => settings);
        when(() => mocks.settings.setQualityMode(any())).thenAnswer((call) {
          settings = settings.copyWith(
            qualityMode: call.positionalArguments.single as QualityMode,
          );
        });
      },
      build: () => mocks.build(),
      seed: ready,
      act: (cubit) async {
        final engines = Completer<List<TranslationEngine>>();
        when(() => mocks.repository.getEngines(refresh: true))
            .thenAnswer((_) => engines.future);
        final load = cubit.loadEngines(refresh: true);
        await cubit.setQualityMode(QualityMode.best);
        engines.complete(allEngines);
        await load;
      },
      verify: (cubit) {
        expect(cubit.state.engine, claude);
        expect(cubit.state.qualityMode, QualityMode.best);
        expect(cubit.state.enginesStatus, EnginesStatus.ready);
        verifyNever(() => mocks.settings.setEngine(any()));
      },
    );

    blocTest<TranslateCubit, TranslateState>(
      'an engine picked during a load still becomes the normal engine',
      setUp: () => mocks.stubSettings(configured),
      build: () => mocks.build(),
      seed: ready,
      act: (cubit) async {
        final engines = Completer<List<TranslationEngine>>();
        when(() => mocks.repository.getEngines(refresh: true))
            .thenAnswer((_) => engines.future);
        final load = cubit.loadEngines(refresh: true);
        await cubit.selectEngine(deepl);
        engines.complete(allEngines);
        await load;
      },
      verify: (cubit) {
        expect(cubit.state.engine, deepl);
        expect(cubit.state.qualityMode, QualityMode.off);
        verify(() => mocks.settings.setEngine('mozhi:deepl')).called(2);
      },
    );
  });

  group('an engine reload that changes the engine', () {
    const paragraph = 'A paragraph the user translated with Google.';

    /// Best = Claude was unavailable: Google translated [paragraph]; now
    /// Claude is back.
    TranslateState googleResult() => readyState(
      input: paragraph,
      engines: const [google, deepl],
      result: resultOf('Ein Absatz'),
      status: TranslateStatus.success,
    );

    blocTest<TranslateCubit, TranslateState>(
      'does not send the input to a paid AI engine on its own',
      setUp: () {
        mocks
          ..stubSettings(configured.copyWith(qualityMode: QualityMode.best))
          ..stubTranslate();
      },
      build: () => mocks.build(),
      seed: googleResult,
      act: (cubit) => cubit.loadEngines(refresh: true),
      verify: (cubit) {
        expect(cubit.state.engine, claude);
        expect(cubit.state.qualityMode, QualityMode.best);
        expect(cubit.state.result, isNull);
        expect(cubit.state.input, paragraph);
        verifyNever(() => mocks.repository.translate(any(), any()));
      },
    );

    blocTest<TranslateCubit, TranslateState>(
      'translates again when instant AI translation is on',
      setUp: () {
        mocks
          ..stubSettings(
            configured.copyWith(
              qualityMode: QualityMode.best,
              instantTranslateAi: true,
            ),
          )
          ..stubTranslate();
      },
      build: () => mocks.build(),
      seed: googleResult,
      act: (cubit) => cubit.loadEngines(refresh: true),
      verify: (cubit) {
        expect(cubit.state.output, '$paragraph->en');
        expect(cubit.state.instantResult, isTrue);
        verify(() => mocks.repository.translate(claude, any())).called(1);
      },
    );

    blocTest<TranslateCubit, TranslateState>(
      'does not translate when instant translation is off',
      setUp: () {
        mocks
          ..stubSettings(
            const AppSettings(engineId: 'mozhi:deepl', instantTranslate: false),
          )
          ..stubTranslate();
      },
      build: () => mocks.build(),
      seed: googleResult,
      act: (cubit) => cubit.loadEngines(refresh: true),
      verify: (cubit) {
        expect(cubit.state.engine, deepl);
        verifyNever(() => mocks.repository.translate(any(), any()));
      },
    );

    blocTest<TranslateCubit, TranslateState>(
      'translates again with a free engine and instant translation on',
      setUp: () {
        mocks
          ..stubSettings(const AppSettings(engineId: 'mozhi:deepl'))
          ..stubTranslate();
      },
      build: () => mocks.build(),
      seed: googleResult,
      act: (cubit) => cubit.loadEngines(refresh: true),
      verify: (cubit) {
        expect(cubit.state.engine, deepl);
        verify(() => mocks.repository.translate(deepl, any())).called(1);
      },
    );
  });

  group('setQualityMode', () {
    setUp(() => mocks.stubSettings(configured));

    blocTest<TranslateCubit, TranslateState>(
      'switches to the mode engine, saves the mode and translates again',
      setUp: () => mocks.stubTranslate(),
      build: () => mocks.build(),
      seed: () => ready(input: 'hi'),
      act: (cubit) => cubit.setQualityMode(QualityMode.best),
      verify: (cubit) {
        expect(cubit.state.engine, claude);
        expect(cubit.state.qualityMode, QualityMode.best);
        expect(cubit.state.output, 'hi->en');
        verify(() => mocks.repository.translate(claude, any())).called(1);
        verify(() => mocks.settings.setQualityMode(QualityMode.best)).called(1);
        // The normal engine stays Google.
        verifyNever(() => mocks.settings.setEngine(any()));
      },
    );

    blocTest<TranslateCubit, TranslateState>(
      'off returns to the normal engine',
      setUp: () {
        mocks
          ..stubSettings(configured.copyWith(qualityMode: QualityMode.best))
          ..stubTranslate();
      },
      build: () => mocks.build(),
      seed: () => ready(engine: claude, mode: QualityMode.best, input: 'hi'),
      act: (cubit) => cubit.setQualityMode(QualityMode.off),
      verify: (cubit) {
        expect(cubit.state.engine, google);
        expect(cubit.state.qualityMode, QualityMode.off);
        verify(() => mocks.settings.setQualityMode(QualityMode.off)).called(1);
        verify(() => mocks.repository.translate(google, any())).called(1);
      },
    );

    blocTest<TranslateCubit, TranslateState>(
      'off uses the default engine when the normal one is unavailable',
      setUp: () => mocks.stubSettings(
        configured.copyWith(
          engineId: () => 'mozhi:gone',
          qualityMode: QualityMode.best,
        ),
      ),
      build: () => mocks.build(),
      seed: () => ready(engine: claude, mode: QualityMode.best),
      act: (cubit) => cubit.setQualityMode(QualityMode.off),
      verify: (cubit) {
        expect(cubit.state.engine, google);
        expect(cubit.state.qualityMode, QualityMode.off);
        // The saved normal engine is kept for when it comes back.
        verifyNever(() => mocks.settings.setEngine(any()));
      },
    );

    blocTest<TranslateCubit, TranslateState>(
      'off goes back to the engine in use before when none was ever picked',
      setUp: () =>
          mocks.stubSettings(const AppSettings(bestEngineId: 'ai:claude')),
      build: () => mocks.build(),
      seed: () => readyState(engine: deepl).copyWith(bestEngine: () => claude),
      act: (cubit) async {
        await cubit.setQualityMode(QualityMode.best);
        expect(cubit.state.engine, claude);
        await cubit.setQualityMode(QualityMode.off);
      },
      verify: (cubit) {
        expect(cubit.state.engine, deepl);
        expect(cubit.state.qualityMode, QualityMode.off);
        // The fallback becomes the normal engine (also after a restart).
        verify(() => mocks.settings.setEngine('mozhi:deepl')).called(1);
      },
    );

    blocTest<TranslateCubit, TranslateState>(
      'off after a restart in a mode, without a normal engine, uses the '
      'default engine',
      setUp: () => mocks.stubSettings(
        const AppSettings(
          bestEngineId: 'ai:claude',
          qualityMode: QualityMode.best,
        ),
      ),
      build: () => mocks.build(),
      seed: () => readyState(engine: claude)
          .copyWith(qualityMode: QualityMode.best, bestEngine: () => claude),
      act: (cubit) => cubit.setQualityMode(QualityMode.off),
      verify: (cubit) {
        expect(cubit.state.engine, google);
        expect(cubit.state.qualityMode, QualityMode.off);
      },
    );

    blocTest<TranslateCubit, TranslateState>(
      'off never stays on the mode engine while another one is available',
      setUp: () => mocks.stubSettings(
        const AppSettings(
          bestEngineId: 'ai:claude',
          qualityMode: QualityMode.best,
        ),
      ),
      build: () => mocks.build(),
      seed: () => readyState(
        engine: claude,
        engines: const [claude, deepl],
      ).copyWith(qualityMode: QualityMode.best, bestEngine: () => claude),
      act: (cubit) => cubit.setQualityMode(QualityMode.off),
      verify: (cubit) {
        expect(cubit.state.engine, deepl);
        expect(cubit.state.qualityMode, QualityMode.off);
      },
    );

    blocTest<TranslateCubit, TranslateState>(
      'off keeps the engine when it is the only one',
      setUp: () => mocks.stubSettings(
        const AppSettings(
          bestEngineId: 'ai:claude',
          qualityMode: QualityMode.best,
        ),
      ),
      build: () => mocks.build(),
      seed: () => readyState(
        engine: claude,
        engines: const [claude],
      ).copyWith(qualityMode: QualityMode.best, bestEngine: () => claude),
      act: (cubit) => cubit.setQualityMode(QualityMode.off),
      expect: () => [
        readyState(
          engine: claude,
          engines: const [claude],
        ).copyWith(bestEngine: () => claude),
      ],
    );

    blocTest<TranslateCubit, TranslateState>(
      'off while already off only saves the mode',
      setUp: () => mocks.stubSettings(
        configured.copyWith(
          engineId: () => 'mozhi:deepl',
          qualityMode: QualityMode.best,
        ),
      ),
      build: () => mocks.build(),
      // The saved mode's engine was unavailable when engines loaded.
      seed: ready,
      act: (cubit) => cubit.setQualityMode(QualityMode.off),
      expect: () => <TranslateState>[],
      verify: (cubit) {
        expect(cubit.state.engine, google);
        verify(() => mocks.settings.setQualityMode(QualityMode.off)).called(1);
      },
    );

    blocTest<TranslateCubit, TranslateState>(
      'switching between modes keeps the engine to go back to',
      setUp: () {
        mocks
          ..stubSettings(
            const AppSettings(
              fastEngineId: 'mozhi:deepl',
              bestEngineId: 'ai:claude',
            ),
          )
          ..stubTranslate();
      },
      build: () => mocks.build(),
      seed: ready,
      act: (cubit) async {
        await cubit.setQualityMode(QualityMode.fast);
        await cubit.setQualityMode(QualityMode.best);
        await cubit.setQualityMode(QualityMode.off);
      },
      verify: (cubit) => expect(cubit.state.engine, google),
    );

    blocTest<TranslateCubit, TranslateState>(
      'changes nothing for a mode without an available engine',
      setUp: () =>
          mocks.stubSettings(configured.copyWith(fastEngineId: () => null)),
      build: () => mocks.build(),
      seed: ready,
      act: (cubit) => cubit.setQualityMode(QualityMode.fast),
      expect: () => <TranslateState>[],
      verify: (_) {
        verifyNever(() => mocks.settings.setQualityMode(any()));
      },
    );

    blocTest<TranslateCubit, TranslateState>(
      'only changes the mode when its engine is the current one',
      setUp: () => mocks.stubSettings(
        configured.copyWith(fastEngineId: () => 'mozhi:google'),
      ),
      build: () => mocks.build(),
      seed: () => ready(input: 'hi'),
      act: (cubit) => cubit.setQualityMode(QualityMode.fast),
      expect: () => [ready(input: 'hi', mode: QualityMode.fast)],
      verify: (_) {
        verifyNever(() => mocks.repository.translate(any(), any()));
      },
    );

    blocTest<TranslateCubit, TranslateState>(
      'does not translate in compare mode or without input',
      build: () => mocks.build(),
      act: (cubit) async {
        cubit.emit(ready(input: 'hi').copyWith(compareMode: true));
        await cubit.setQualityMode(QualityMode.best);
        cubit.emit(ready());
        await cubit.setQualityMode(QualityMode.fast);
      },
      verify: (cubit) {
        expect(cubit.state.engine, deepl);
        verifyNever(() => mocks.repository.translate(any(), any()));
      },
    );
  });

  group('choosing an engine turns quality mode off', () {
    setUp(() {
      mocks
        ..stubSettings(configured.copyWith(qualityMode: QualityMode.best))
        ..stubTranslate();
    });

    blocTest<TranslateCubit, TranslateState>(
      'selectEngine saves the pick as the normal engine',
      build: () => mocks.build(),
      seed: () => ready(engine: claude, mode: QualityMode.best),
      act: (cubit) => cubit.selectEngine(deepl),
      verify: (cubit) {
        expect(cubit.state.engine, deepl);
        expect(cubit.state.qualityMode, QualityMode.off);
        verify(() => mocks.settings.setQualityMode(QualityMode.off)).called(1);
        verify(() => mocks.settings.setEngine('mozhi:deepl')).called(1);
      },
    );

    blocTest<TranslateCubit, TranslateState>(
      "selecting the mode's own engine makes it the normal engine",
      build: () => mocks.build(),
      seed: () => ready(engine: claude, mode: QualityMode.best),
      act: (cubit) => cubit.selectEngine(claude),
      expect: () => [ready(engine: claude)],
      verify: (_) {
        verify(() => mocks.settings.setEngine('ai:claude')).called(1);
      },
    );

    blocTest<TranslateCubit, TranslateState>(
      'picking a compare result of another engine',
      build: () => mocks.build(),
      seed: () => ready(engine: claude, mode: QualityMode.best, input: 'hi'),
      act: (cubit) async {
        cubit.useCompareEntry(
          CompareEntry.success(resultOf('hallo', engine: deepl)),
        );
        await Future<void>.delayed(Duration.zero);
      },
      verify: (cubit) {
        expect(cubit.state.engine, deepl);
        expect(cubit.state.qualityMode, QualityMode.off);
        verify(() => mocks.settings.setEngine('mozhi:deepl')).called(1);
      },
    );
  });

  group('settings changes', () {
    late StreamController<AppSettings> settings;

    setUp(() {
      settings = StreamController<AppSettings>();
      addTearDown(settings.close);
      when(() => mocks.settings.stream).thenAnswer((_) => settings.stream);
    });

    Future<void> change(AppSettings value) async {
      mocks.stubSettings(value);
      settings.add(value);
      await Future<void>.delayed(Duration.zero);
    }

    blocTest<TranslateCubit, TranslateState>(
      'make newly configured modes available',
      build: () => mocks.build(),
      seed: readyState,
      act: (cubit) => change(const AppSettings(fastEngineId: 'mozhi:deepl')),
      expect: () => [readyState().copyWith(fastEngine: () => deepl)],
    );

    blocTest<TranslateCubit, TranslateState>(
      'are ignored when the quality engines stay the same',
      setUp: () => mocks.stubSettings(configured),
      build: () => mocks.build(),
      seed: ready,
      act: (cubit) => change(configured.copyWith(saveHistory: false)),
      expect: () => <TranslateState>[],
    );

    blocTest<TranslateCubit, TranslateState>(
      'switch to the new engine of the active mode, keeping the output',
      setUp: () => mocks.stubSettings(
        configured.copyWith(qualityMode: QualityMode.best),
      ),
      build: () => mocks.build(),
      seed: () =>
          ready(engine: claude, mode: QualityMode.best, input: 'hi').copyWith(
            result: () => resultOf('hallo', engine: claude),
            resultInput: () => 'hi',
            status: TranslateStatus.success,
          ),
      act: (cubit) async {
        await change(
          configured.copyWith(
            bestEngineId: () => 'mozhi:deepl',
            qualityMode: QualityMode.best,
          ),
        );
        await Future<void>.delayed(Duration.zero);
      },
      verify: (cubit) {
        expect(cubit.state.engine, deepl);
        expect(cubit.state.bestEngine, deepl);
        expect(cubit.state.qualityMode, QualityMode.best);
        expect(cubit.state.output, 'hallo');
        verifyNever(() => mocks.settings.setEngine(any()));
        verifyNever(() => mocks.repository.translate(any(), any()));
      },
    );

    blocTest<TranslateCubit, TranslateState>(
      'turn the mode off when its engine is removed',
      setUp: () => mocks.stubSettings(
        configured.copyWith(qualityMode: QualityMode.best),
      ),
      build: () => mocks.build(),
      seed: () => ready(engine: claude, mode: QualityMode.best),
      act: (cubit) async {
        await change(
          configured.copyWith(
            bestEngineId: () => null,
            qualityMode: QualityMode.best,
          ),
        );
        await Future<void>.delayed(Duration.zero);
      },
      verify: (cubit) {
        expect(cubit.state.engine, google);
        expect(cubit.state.qualityMode, QualityMode.off);
        expect(cubit.state.bestEngine, isNull);
        verify(() => mocks.settings.setQualityMode(QualityMode.off)).called(1);
        verifyNever(() => mocks.settings.setEngine(any()));
      },
    );

    blocTest<TranslateCubit, TranslateState>(
      'without a normal engine, a removed mode engine gives way to the '
      'default one',
      setUp: () => mocks.stubSettings(
        const AppSettings(
          bestEngineId: 'ai:claude',
          qualityMode: QualityMode.best,
        ),
      ),
      build: () => mocks.build(),
      seed: () => readyState(engine: claude)
          .copyWith(qualityMode: QualityMode.best, bestEngine: () => claude),
      act: (cubit) async {
        await change(const AppSettings(qualityMode: QualityMode.best));
        await Future<void>.delayed(Duration.zero);
      },
      verify: (cubit) {
        expect(cubit.state.engine, google);
        expect(cubit.state.qualityMode, QualityMode.off);
      },
    );

    blocTest<TranslateCubit, TranslateState>(
      'leave the engine alone while engines load',
      setUp: () => mocks.stubSettings(
        configured.copyWith(qualityMode: QualityMode.best),
      ),
      build: () => mocks.build(),
      seed: () => ready(
        engine: claude,
        mode: QualityMode.best,
      ).copyWith(enginesStatus: EnginesStatus.loading),
      act: (cubit) => change(
        configured.copyWith(
          bestEngineId: () => 'mozhi:deepl',
          qualityMode: QualityMode.best,
        ),
      ),
      verify: (cubit) {
        expect(cubit.state.engine, claude);
        expect(cubit.state.bestEngine, deepl);
      },
    );
  });
}
