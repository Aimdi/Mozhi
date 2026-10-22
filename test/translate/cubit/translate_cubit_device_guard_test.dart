import 'package:bloc_test/bloc_test.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:mocktail/mocktail.dart';
import 'package:mozhi/platform/device_conditions.dart';
import 'package:mozhi/settings/models/app_settings.dart';
import 'package:mozhi/translate/cubit/translate_cubit.dart';
import 'package:translation_repository/translation_repository.dart';

import 'translate_cubit_helpers.dart';

/// Hy-MT2 on this device (an on-device AI engine).
const onDevice = TranslationEngine(
  id: 'ai:device-hy-mt2-1.8b-q4',
  kind: EngineKind.ai,
  name: 'Hy-MT2 1.8B (on this device)',
  providerId: 'device-hy-mt2-1.8b-q4',
  isLocal: true,
  onDevice: true,
  promptProfile: PromptProfile.hunyuanMt,
);

/// Qwen3 on this device (an on-device assistant model).
const qwen = TranslationEngine(
  id: 'ai:device-qwen3-1.7b-q4',
  kind: EngineKind.ai,
  name: 'Qwen3 1.7B (on this device)',
  providerId: 'device-qwen3-1.7b-q4',
  isLocal: true,
  onDevice: true,
  promptProfile: PromptProfile.general,
);

class _FakeConditions extends Fake implements DeviceConditions {
  DeviceConditionsSnapshot snapshot = DeviceConditionsSnapshot.unknown;
  int reads = 0;

  @override
  DeviceConditionsSnapshot get latest {
    reads++;
    return snapshot;
  }
}

const _hot = DeviceConditionsSnapshot(thermal: ThermalStatus.severe);
const _batterySaver = DeviceConditionsSnapshot(powerSave: true);

void main() {
  setUpAll(registerTranslateFallbacks);

  late TranslateMocks mocks;
  late _FakeConditions conditions;

  setUp(() {
    mocks = TranslateMocks()
      ..stubTranslate()
      ..stubSettings(const AppSettings());
    conditions = _FakeConditions();
  });

  TranslateCubit build({bool injected = true}) => TranslateCubit(
    repository: mocks.repository,
    settings: mocks.settings,
    history: mocks.history,
    debounce: fastDebounce,
    aiDebounce: fastAiDebounce,
    deviceLanguages: () => const [],
    deviceConditions: injected ? conditions : null,
  );

  TranslateState seed({TranslationEngine engine = onDevice}) => readyState(
    engine: engine,
    engines: [...allEngines, onDevice],
    source: de,
  );

  group('typing with on-device AI', () {
    blocTest<TranslateCubit, TranslateState>(
      'translates while the phone is fine',
      build: build,
      seed: seed,
      act: (cubit) async {
        cubit.setInput('hallo');
        await Future<void>.delayed(afterDebounce);
      },
      verify: (cubit) {
        verify(() => mocks.repository.translate(onDevice, any())).called(1);
        expect(cubit.state.instantResult, isTrue);
      },
    );

    for (final (name, snapshot) in [
      ('hot', _hot),
      ('saving battery', _batterySaver),
    ]) {
      blocTest<TranslateCubit, TranslateState>(
        'waits for Translate while the phone is $name',
        setUp: () => conditions.snapshot = snapshot,
        build: build,
        seed: seed,
        act: (cubit) async {
          cubit.setInput('hallo');
          expect(cubit.state.queued, isFalse);
          await Future<void>.delayed(afterDebounce);
          verifyNever(() => mocks.repository.translate(any(), any()));
          // The go button (or Enter with single-line input).
          await cubit.translate();
        },
        verify: (cubit) {
          verify(() => mocks.repository.translate(onDevice, any())).called(1);
          expect(cubit.state.output, 'hallo->en');
        },
      );
    }

    blocTest<TranslateCubit, TranslateState>(
      'translates a new line (Enter with multiline input) even then',
      setUp: () => conditions.snapshot = _hot,
      build: build,
      seed: () => seed().copyWith(input: 'hallo'),
      act: (cubit) async {
        cubit.setInput('hallo\n');
        expect(cubit.state.queued, isTrue);
        await Future<void>.delayed(afterDebounce);
      },
      verify: (_) {
        verify(() => mocks.repository.translate(onDevice, any())).called(1);
      },
    );

    blocTest<TranslateCubit, TranslateState>(
      'drops a queued translation when the phone got hot meanwhile',
      build: build,
      seed: seed,
      act: (cubit) async {
        cubit.setInput('hallo');
        expect(cubit.state.queued, isTrue);
        conditions.snapshot = _hot;
        await Future<void>.delayed(afterDebounce);
        expect(cubit.state.queued, isFalse);
      },
      verify: (_) {
        verifyNever(() => mocks.repository.translate(any(), any()));
      },
    );

    blocTest<TranslateCubit, TranslateState>(
      'follows the app-wide conditions by default (none off Android)',
      build: () => build(injected: false),
      seed: seed,
      act: (cubit) async {
        cubit.setInput('hallo');
        await Future<void>.delayed(afterDebounce);
      },
      verify: (_) {
        verify(() => mocks.repository.translate(onDevice, any())).called(1);
      },
    );
  });

  blocTest<TranslateCubit, TranslateState>(
    'other engines translate while typing whatever the conditions',
    setUp: () => conditions.snapshot = _hot,
    build: build,
    seed: () => seed(engine: claude),
    act: (cubit) async {
      cubit.setInput('hallo');
      await Future<void>.delayed(afterDebounce);
    },
    verify: (_) {
      verify(() => mocks.repository.translate(claude, any())).called(1);
      // Never asked for them.
      expect(conditions.reads, 0);
    },
  );
  group('automatic romanization with an on-device assistant', () {
    setUp(() {
      when(
        () => mocks.repository.romanize(
          any(),
          text: any(named: 'text'),
          language: any(named: 'language'),
        ),
      ).thenAnswer((_) async => 'romaji');
    });

    TranslateState japanese() => readyState(
      engines: [...allEngines, qwen],
      assistEngine: qwen,
      target: ja,
    );

    int romanizations() => verify(
      () => mocks.repository.romanize(
        qwen,
        text: any(named: 'text'),
        language: any(named: 'language'),
      ),
    ).callCount;

    blocTest<TranslateCubit, TranslateState>(
      'follows typing while the phone is fine',
      build: build,
      seed: japanese,
      act: (cubit) async {
        cubit.setInput('hello');
        await Future<void>.delayed(afterDebounce);
      },
      verify: (cubit) {
        expect(romanizations(), 1);
        expect(cubit.state.romanization, 'romaji');
      },
    );

    blocTest<TranslateCubit, TranslateState>(
      'waits for Translate while the phone is hot',
      setUp: () => conditions.snapshot = _hot,
      build: build,
      seed: japanese,
      act: (cubit) async {
        cubit.setInput('hello');
        await Future<void>.delayed(afterDebounce);
        // The instant translation (Google) came, its romanization did not.
        expect(cubit.state.output, 'hello->ja');
        verifyNever(
          () => mocks.repository.romanize(
            any(),
            text: any(named: 'text'),
            language: any(named: 'language'),
          ),
        );
        await cubit.translate();
        await Future<void>.delayed(Duration.zero);
      },
      verify: (_) => expect(romanizations(), 1),
    );
  });
}
