import 'package:bloc_test/bloc_test.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:material_ui/material_ui.dart';
import 'package:mocktail/mocktail.dart';
import 'package:mozhi/settings/cubit/settings_cubit.dart';
import 'package:mozhi/settings/data/settings_repository.dart';
import 'package:mozhi/settings/models/app_settings.dart';
import 'package:translation_repository/translation_repository.dart';

class _MockSettingsRepository extends Mock implements SettingsRepository;

const _a = MozhiInstance(url: 'https://a.example');
const _b = MozhiInstance(url: 'https://b.example');
const _c = MozhiInstance(url: 'https://c.example');
const _d = MozhiInstance(url: 'https://d.example');

const _french = Language(code: 'fr', name: 'French');
const _german = Language(code: 'de', name: 'German');

AiProviderConfig _provider(String id, {bool enabled = true}) =>
    AiProviderConfig(
      id: id,
      name: 'Provider $id',
      provider: LlmProvider.openAiCompatible,
      baseUrl: 'https://api.example.com/v1',
      model: 'model',
      enabled: enabled,
    );

List<Language> _languages(int count) => [
  for (var i = 0; i < count; i++) Language(code: 'l$i', name: 'Language $i'),
];

void main() {
  late SettingsRepository repository;

  setUpAll(() {
    registerFallbackValue(const AppSettings());
  });

  setUp(() {
    repository = _MockSettingsRepository();
    when(() => repository.save(any())).thenAnswer((_) async {});
  });

  SettingsCubit buildCubit([AppSettings initial = const AppSettings()]) =>
      SettingsCubit(repository: repository, initial: initial);

  /// bloc_test case for a mutation that emits [expected] and persists it.
  void mutation(
    String description, {
    required void Function(SettingsCubit cubit) act,
    required AppSettings expected,
    AppSettings initial = const AppSettings(),
  }) {
    blocTest<SettingsCubit, AppSettings>(
      description,
      build: () => buildCubit(initial),
      act: act,
      expect: () => [expected],
      verify: (_) => verify(() => repository.save(expected)).called(1),
    );
  }

  /// bloc_test case for a call that must neither emit nor persist.
  void noOp(
    String description, {
    required void Function(SettingsCubit cubit) act,
    AppSettings initial = const AppSettings(),
  }) {
    blocTest<SettingsCubit, AppSettings>(
      description,
      build: () => buildCubit(initial),
      act: act,
      expect: () => <AppSettings>[],
      verify: (_) => verifyNever(() => repository.save(any())),
    );
  }

  group(SettingsCubit, () {
    test('starts with the given settings or the defaults', () {
      expect(
        SettingsCubit(repository: repository).state,
        equals(const AppSettings()),
      );
      expect(
        buildCubit(const AppSettings(pureBlack: true)).state.pureBlack,
        isTrue,
      );
    });

    test('can be created with the default repository', () async {
      final cubit = SettingsCubit();
      expect(cubit.state, equals(const AppSettings()));
      await cubit.close();
    });

    group('load', () {
      blocTest<SettingsCubit, AppSettings>(
        'emits the stored settings',
        setUp: () =>
            when(() => repository.load())
                .thenAnswer((_) async => const AppSettings(seedColor: 7)),
        build: buildCubit,
        act: (cubit) => cubit.load(),
        expect: () => [const AppSettings(seedColor: 7)],
        verify: (_) => verifyNever(() => repository.save(any())),
      );

      blocTest<SettingsCubit, AppSettings>(
        'reports errors without emitting',
        setUp: () =>
            when(() => repository.load()).thenThrow(StateError('broken')),
        build: buildCubit,
        act: (cubit) => cubit.load(),
        expect: () => <AppSettings>[],
        errors: () => [isA<StateError>()],
      );

      blocTest<SettingsCubit, AppSettings>(
        'does not emit after close',
        setUp: () =>
            when(() => repository.load())
                .thenAnswer((_) async => const AppSettings(seedColor: 7)),
        build: buildCubit,
        act: (cubit) async {
          final load = cubit.load();
          await cubit.close();
          await load;
        },
        expect: () => <AppSettings>[],
      );
    });

    group('persistence', () {
      blocTest<SettingsCubit, AppSettings>(
        'reports save errors via addError',
        setUp: () =>
            when(() => repository.save(any())).thenThrow(StateError('disk')),
        build: buildCubit,
        act: (cubit) => cubit.setPureBlack(enabled: true),
        expect: () => [const AppSettings(pureBlack: true)],
        errors: () => [isA<StateError>()],
      );

      blocTest<SettingsCubit, AppSettings>(
        'reports asynchronous save errors via addError',
        setUp: () =>
            when(() => repository.save(any()))
                .thenAnswer((_) => Future.error(StateError('disk'))),
        build: buildCubit,
        act: (cubit) => cubit.setPureBlack(enabled: true),
        expect: () => [const AppSettings(pureBlack: true)],
        errors: () => [isA<StateError>()],
      );

      noOp(
        'does not emit or save unchanged settings',
        act: (cubit) => cubit.setThemeMode(ThemeMode.system),
      );

      blocTest<SettingsCubit, AppSettings>(
        'ignores changes after close',
        build: buildCubit,
        act: (cubit) async {
          await cubit.close();
          cubit.setPureBlack(enabled: true);
        },
        expect: () => <AppSettings>[],
        verify: (_) => verifyNever(() => repository.save(any())),
      );

      mutation(
        'update applies an arbitrary change',
        act: (cubit) => cubit.update((s) => s.copyWith(seedColor: 42)),
        expected: const AppSettings(seedColor: 42),
      );
    });

    group('appearance', () {
      mutation(
        'setThemeMode',
        act: (cubit) => cubit.setThemeMode(ThemeMode.dark),
        expected: const AppSettings(themeMode: ThemeMode.dark),
      );
      mutation(
        'setDynamicColor',
        act: (cubit) => cubit.setDynamicColor(enabled: false),
        expected: const AppSettings(dynamicColor: false),
      );
      mutation(
        'setPureBlack',
        act: (cubit) => cubit.setPureBlack(enabled: true),
        expected: const AppSettings(pureBlack: true),
      );
      mutation(
        'setSeedColor',
        act: (cubit) => cubit.setSeedColor(0xFF00FF00),
        expected: const AppSettings(seedColor: 0xFF00FF00),
      );
    });

    group('instances', () {
      const initial = AppSettings(instances: [_a, _b, _c]);

      mutation(
        'addInstance appends a new instance',
        initial: initial,
        act: (cubit) => cubit.addInstance(_d),
        expected: const AppSettings(instances: [_a, _b, _c, _d]),
      );

      mutation(
        'addInstance replaces an instance with the same url in place',
        initial: initial,
        act: (cubit) => cubit.addInstance(
          const MozhiInstance(url: 'https://b.example', label: 'B'),
        ),
        expected: const AppSettings(
          instances: [
            _a,
            MozhiInstance(url: 'https://b.example', label: 'B'),
            _c,
          ],
        ),
      );

      mutation(
        'removeInstance removes by url',
        initial: initial,
        act: (cubit) => cubit.removeInstance(_b.url),
        expected: const AppSettings(instances: [_a, _c]),
      );

      mutation(
        'removeInstance may leave the list empty',
        initial: const AppSettings(instances: [_a]),
        act: (cubit) => cubit.removeInstance(_a.url),
        expected: const AppSettings(instances: []),
      );

      noOp(
        'removeInstance ignores unknown urls',
        initial: initial,
        act: (cubit) => cubit.removeInstance(_d.url),
      );

      mutation(
        'moveInstance moves down with ReorderableListView semantics',
        initial: initial,
        act: (cubit) => cubit.moveInstance(0, 3),
        expected: const AppSettings(instances: [_b, _c, _a]),
      );

      mutation(
        'moveInstance moves up',
        initial: initial,
        act: (cubit) => cubit.moveInstance(2, 0),
        expected: const AppSettings(instances: [_c, _a, _b]),
      );

      mutation(
        'moveInstance clamps the target index',
        initial: initial,
        act: (cubit) => cubit.moveInstance(0, 10),
        expected: const AppSettings(instances: [_b, _c, _a]),
      );

      noOp(
        'moveInstance ignores moves onto the same position',
        initial: initial,
        act: (cubit) => cubit.moveInstance(1, 2),
      );

      noOp(
        'moveInstance ignores invalid source indices',
        initial: initial,
        act: (cubit) => cubit
          ..moveInstance(-1, 0)
          ..moveInstance(3, 0),
      );

      mutation(
        'preferInstance moves the instance to the front',
        initial: initial,
        act: (cubit) => cubit.preferInstance(_c.url),
        expected: const AppSettings(instances: [_c, _a, _b]),
      );

      noOp(
        'preferInstance ignores the first and unknown instances',
        initial: initial,
        act: (cubit) => cubit
          ..preferInstance(_a.url)
          ..preferInstance(_d.url),
      );

      mutation(
        'resetInstances restores the public instances',
        initial: initial,
        act: (cubit) => cubit.resetInstances(),
        expected: const AppSettings(),
      );
    });

    group('providers', () {
      mutation(
        'saveProvider appends a new provider',
        initial: AppSettings(providers: [_provider('a')]),
        act: (cubit) => cubit.saveProvider(_provider('b')),
        expected: AppSettings(providers: [_provider('a'), _provider('b')]),
      );

      mutation(
        'saveProvider replaces a provider with the same id',
        initial: AppSettings(providers: [_provider('a'), _provider('b')]),
        act: (cubit) =>
            cubit.saveProvider(_provider('a').copyWith(model: 'other')),
        expected: AppSettings(
          providers: [
            _provider('a').copyWith(model: 'other'),
            _provider('b'),
          ],
        ),
      );

      mutation(
        'removeProvider clears selections pointing at it',
        initial: AppSettings(
          providers: [_provider('a'), _provider('b')],
          engineId: 'ai:a',
          assistEngineId: 'ai:a',
          compareEngineIds: const ['mozhi:google', 'ai:a', 'ai:b'],
        ),
        act: (cubit) => cubit.removeProvider('a'),
        expected: AppSettings(
          providers: [_provider('b')],
          compareEngineIds: const ['mozhi:google', 'ai:b'],
        ),
      );

      mutation(
        'removeProvider keeps selections of other engines',
        initial: AppSettings(
          providers: [_provider('a'), _provider('b')],
          engineId: 'mozhi:google',
          assistEngineId: 'ai:b',
        ),
        act: (cubit) => cubit.removeProvider('a'),
        expected: AppSettings(
          providers: [_provider('b')],
          engineId: 'mozhi:google',
          assistEngineId: 'ai:b',
        ),
      );

      mutation(
        'setProviderEnabled toggles only the given provider',
        initial: AppSettings(providers: [_provider('a'), _provider('b')]),
        act: (cubit) => cubit.setProviderEnabled('b', enabled: false),
        expected: AppSettings(
          providers: [_provider('a'), _provider('b', enabled: false)],
        ),
      );
    });

    group('translation defaults', () {
      mutation(
        'setEngine selects an engine',
        act: (cubit) => cubit.setEngine('mozhi:deepl'),
        expected: const AppSettings(engineId: 'mozhi:deepl'),
      );

      mutation(
        'setEngine(null) resets the selection',
        initial: const AppSettings(engineId: 'mozhi:deepl'),
        act: (cubit) => cubit.setEngine(null),
        expected: const AppSettings(),
      );

      mutation(
        'setAssistEngine selects an assist engine',
        act: (cubit) => cubit.setAssistEngine('ai:a'),
        expected: const AppSettings(assistEngineId: 'ai:a'),
      );

      mutation(
        'setLanguages replaces both languages',
        act: (cubit) => cubit.setLanguages(source: _french, target: _german),
        expected: const AppSettings(source: _french, target: _german),
      );

      mutation(
        'setLanguages keeps languages that are not given',
        initial: const AppSettings(source: _french),
        act: (cubit) => cubit.setLanguages(target: _german),
        expected: const AppSettings(source: _french, target: _german),
      );

      mutation(
        'setOptions',
        act: (cubit) => cubit.setOptions(
          const TranslationOptions(formality: Formality.less),
        ),
        expected: const AppSettings(
          options: TranslationOptions(formality: Formality.less),
        ),
      );

      mutation(
        'setInstantTranslate',
        act: (cubit) => cubit.setInstantTranslate(enabled: false),
        expected: const AppSettings(instantTranslate: false),
      );
      mutation(
        'setInstantTranslateAi',
        act: (cubit) => cubit.setInstantTranslateAi(enabled: true),
        expected: const AppSettings(instantTranslateAi: true),
      );
      mutation(
        'setSaveHistory',
        act: (cubit) => cubit.setSaveHistory(enabled: false),
        expected: const AppSettings(saveHistory: false),
      );
      mutation(
        'setShowTransliteration',
        act: (cubit) => cubit.setShowTransliteration(enabled: false),
        expected: const AppSettings(showTransliteration: false),
      );
      mutation(
        'setCompareEngines',
        act: (cubit) => cubit.setCompareEngines(['mozhi:google', 'ai:a']),
        expected: const AppSettings(compareEngineIds: ['mozhi:google', 'ai:a']),
      );
      mutation(
        'completeOnboarding',
        act: (cubit) => cubit.completeOnboarding(),
        expected: const AppSettings(onboardingComplete: true),
      );
    });

    group('recent languages', () {
      mutation(
        'addRecentLanguage pushes to the front',
        initial: const AppSettings(recentLanguages: [_german]),
        act: (cubit) => cubit.addRecentLanguage(_french),
        expected: const AppSettings(recentLanguages: [_french, _german]),
      );

      mutation(
        'addRecentLanguage moves an existing language to the front',
        initial: const AppSettings(recentLanguages: [_german, _french]),
        act: (cubit) => cubit.addRecentLanguage(_french),
        expected: const AppSettings(recentLanguages: [_french, _german]),
      );

      mutation(
        'addRecentLanguage keeps at most eight languages',
        initial: AppSettings(recentLanguages: _languages(8)),
        act: (cubit) => cubit.addRecentLanguage(_french),
        expected: AppSettings(recentLanguages: [_french, ..._languages(7)]),
      );

      mutation(
        'addRecentLanguage stores custom languages',
        act: (cubit) => cubit.addRecentLanguage(const Language.custom('Yoda')),
        expected: const AppSettings(recentLanguages: [Language.custom('Yoda')]),
      );

      noOp(
        'addRecentLanguage never stores auto',
        act: (cubit) => cubit.addRecentLanguage(Language.auto),
      );

      noOp(
        'addRecentLanguage ignores the current most recent language',
        initial: const AppSettings(recentLanguages: [_french, _german]),
        act: (cubit) => cubit.addRecentLanguage(_french),
      );
    });

    group('pinned languages', () {
      mutation(
        'togglePinnedLanguage pins a language',
        initial: const AppSettings(pinnedLanguages: [_german]),
        act: (cubit) => cubit.togglePinnedLanguage(_french),
        expected: const AppSettings(pinnedLanguages: [_german, _french]),
      );

      mutation(
        'togglePinnedLanguage unpins a pinned language',
        initial: const AppSettings(pinnedLanguages: [_german, _french]),
        act: (cubit) => cubit.togglePinnedLanguage(_german),
        expected: const AppSettings(pinnedLanguages: [_french]),
      );
    });
  });
}
