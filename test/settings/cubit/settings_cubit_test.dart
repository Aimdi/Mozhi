import 'dart:async';

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
const _english = Language(code: 'en', name: 'English');

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

const _mirror = ModelSource(
  kind: ModelSourceKind.custom,
  customUrl: 'https://mirror.example/models/',
);

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
        buildCubit(const AppSettings(pureBlack: false)).state.pureBlack,
        isFalse,
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
        act: (cubit) => cubit.setPureBlack(enabled: false),
        expect: () => [const AppSettings(pureBlack: false)],
        errors: () => [isA<StateError>()],
      );

      blocTest<SettingsCubit, AppSettings>(
        'reports asynchronous save errors via addError',
        setUp: () =>
            when(() => repository.save(any()))
                .thenAnswer((_) => Future.error(StateError('disk'))),
        build: buildCubit,
        act: (cubit) => cubit.setPureBlack(enabled: false),
        expect: () => [const AppSettings(pureBlack: false)],
        errors: () => [isA<StateError>()],
      );

      noOp(
        'does not emit or save unchanged settings',
        act: (cubit) => cubit.setThemeMode(ThemeMode.system),
      );

      group('save failures', () {
        test('are reported on saveFailures', () async {
          when(() => repository.save(any()))
              .thenAnswer((_) => Future.error(StateError('disk')));
          final cubit = buildCubit();
          final failures = <SettingsSaveFailure>[];
          final subscription = cubit.saveFailures.listen(failures.add);
          cubit.setPureBlack(enabled: false);
          await pumpEventQueue();
          expect(failures, [SettingsSaveFailure.settings]);
          await subscription.cancel();
          await cubit.close();
        });

        test('say when secure storage refused a secret', () async {
          when(() => repository.save(any())).thenAnswer(
            (_) => Future.error(SecretStorageException(StateError('ks'))),
          );
          final cubit = buildCubit();
          final failures = <SettingsSaveFailure>[];
          cubit.saveFailures.listen(failures.add);
          cubit
            ..setPureBlack(enabled: false)
            ..setSeedColor(1);
          await pumpEventQueue();
          expect(failures, [
            SettingsSaveFailure.secret,
            SettingsSaveFailure.secret,
          ]);
          await cubit.close();
        });

        test('classify unreadable stored settings as a settings failure', () {
          expect(
            SettingsSaveFailure.of(const SettingsUnavailableException()),
            SettingsSaveFailure.settings,
          );
        });

        test('are not reported for successful saves', () async {
          final cubit = buildCubit();
          final failures = <SettingsSaveFailure>[];
          cubit.saveFailures.listen(failures.add);
          cubit.setPureBlack(enabled: false);
          await pumpEventQueue();
          expect(failures, isEmpty);
          await cubit.close();
        });

        test('a save failing after close is not reported', () async {
          final gate = Completer<void>();
          when(() => repository.save(any())).thenAnswer((_) async {
            await gate.future;
            throw StateError('late');
          });
          final cubit = buildCubit();
          final failures = <SettingsSaveFailure>[];
          final done = expectLater(cubit.saveFailures, emitsDone);
          cubit.saveFailures.listen(failures.add);
          cubit.setPureBlack(enabled: false);
          await cubit.close();
          gate.complete();
          await pumpEventQueue();
          await done;
          expect(failures, isEmpty);
        });
      });

      blocTest<SettingsCubit, AppSettings>(
        'ignores changes after close',
        build: buildCubit,
        act: (cubit) async {
          await cubit.close();
          cubit.setPureBlack(enabled: false);
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
        'setPureBlack (Dim)',
        act: (cubit) => cubit.setPureBlack(enabled: false),
        expected: const AppSettings(pureBlack: false),
      );
      mutation(
        'setSeedColor',
        act: (cubit) => cubit.setSeedColor(0xFF00FF00),
        expected: const AppSettings(seedColor: 0xFF00FF00),
      );
    });

    group('general', () {
      mutation(
        'setAppLocale',
        act: (cubit) => cubit.setAppLocale(' de '),
        expected: const AppSettings(appLocale: 'de'),
      );
      mutation(
        'setAppLocale(null) follows the device again',
        initial: const AppSettings(appLocale: 'ja'),
        act: (cubit) => cubit.setAppLocale(null),
        expected: const AppSettings(),
      );
      mutation(
        'setAppLocale with a blank tag follows the device again',
        initial: const AppSettings(appLocale: 'ja'),
        act: (cubit) => cubit.setAppLocale('  '),
        expected: const AppSettings(),
      );
      mutation(
        'setHapticFeedback',
        act: (cubit) => cubit.setHapticFeedback(enabled: false),
        expected: const AppSettings(hapticFeedback: false),
      );
      mutation(
        'setRememberQuality',
        act: (cubit) => cubit.setRememberQuality(enabled: false),
        expected: const AppSettings(rememberQuality: false),
      );
      mutation(
        'setMultilineInput',
        act: (cubit) => cubit.setMultilineInput(enabled: false),
        expected: const AppSettings(multilineInput: false),
      );
      mutation(
        'setTabOrder completes and dedupes the order',
        act: (cubit) => cubit.setTabOrder(const [
          AppTab.proofread,
          AppTab.dictionary,
          AppTab.proofread,
        ]),
        expected: const AppSettings(
          tabOrder: [
            AppTab.proofread,
            AppTab.dictionary,
            AppTab.translate,
            AppTab.conversation,
          ],
        ),
      );
      mutation(
        'moveTab moves a tab down to its final position',
        act: (cubit) => cubit.moveTab(0, 2),
        expected: const AppSettings(
          tabOrder: [
            AppTab.dictionary,
            AppTab.proofread,
            AppTab.translate,
            AppTab.conversation,
          ],
        ),
      );
      mutation(
        'moveTab moves a tab up',
        act: (cubit) => cubit.moveTab(3, 0),
        expected: const AppSettings(
          tabOrder: [
            AppTab.conversation,
            AppTab.translate,
            AppTab.dictionary,
            AppTab.proofread,
          ],
        ),
      );
      mutation(
        'moveTab clamps the target',
        act: (cubit) => cubit.moveTab(1, 9),
        expected: const AppSettings(
          tabOrder: [
            AppTab.translate,
            AppTab.proofread,
            AppTab.conversation,
            AppTab.dictionary,
          ],
        ),
      );
      noOp(
        'moveTab ignores an invalid index',
        act: (cubit) {
          cubit
            ..moveTab(-1, 0)
            ..moveTab(4, 0);
        },
      );
      noOp('moveTab to the same place', act: (cubit) => cubit.moveTab(2, 2));
      mutation(
        'resetTabOrder',
        initial: const AppSettings(
          tabOrder: [
            AppTab.conversation,
            AppTab.translate,
            AppTab.dictionary,
            AppTab.proofread,
          ],
        ),
        act: (cubit) => cubit.resetTabOrder(),
        expected: const AppSettings(),
      );
      noOp(
        'resetTabOrder in the default order',
        act: (cubit) => cubit.resetTabOrder(),
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
        'removeProvider clears the quality engines pointing at it',
        initial: AppSettings(
          providers: [_provider('a'), _provider('b')],
          fastEngineId: 'mt:a',
          bestEngineId: 'ai:a',
          qualityMode: QualityMode.best,
        ),
        act: (cubit) => cubit.removeProvider('a'),
        expected: AppSettings(
          providers: [_provider('b')],
          qualityMode: QualityMode.best,
        ),
      );

      mutation(
        'removeProvider clears selections of its machine translation engine',
        initial: AppSettings(
          providers: [_provider('a')],
          engineId: 'mt:a',
          assistEngineId: 'ai:a',
          compareEngineIds: const ['mt:a', 'mozhi:google'],
        ),
        act: (cubit) => cubit.removeProvider('a'),
        expected: const AppSettings(compareEngineIds: ['mozhi:google']),
      );

      mutation(
        'removeProvider clears the live engine pointing at it',
        initial: AppSettings(
          providers: [_provider('a'), _provider('b')],
          liveEngineId: 'ai:a',
        ),
        act: (cubit) => cubit.removeProvider('a'),
        expected: AppSettings(providers: [_provider('b')]),
      );

      mutation(
        'removeProvider keeps the live engine of another provider',
        initial: AppSettings(
          providers: [_provider('a'), _provider('b')],
          liveEngineId: 'mt:b',
        ),
        act: (cubit) => cubit.removeProvider('a'),
        expected: AppSettings(
          providers: [_provider('b')],
          liveEngineId: 'mt:b',
        ),
      );

      mutation(
        'removeProvider keeps selections of other engines',
        initial: AppSettings(
          providers: [_provider('a'), _provider('b')],
          engineId: 'mozhi:google',
          assistEngineId: 'ai:b',
          fastEngineId: 'mozhi:google',
          bestEngineId: 'ai:b',
        ),
        act: (cubit) => cubit.removeProvider('a'),
        expected: AppSettings(
          providers: [_provider('b')],
          engineId: 'mozhi:google',
          assistEngineId: 'ai:b',
          fastEngineId: 'mozhi:google',
          bestEngineId: 'ai:b',
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
        act: (cubit) => cubit.setInstantTranslateAi(enabled: false),
        expected: const AppSettings(instantTranslateAi: false),
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

    group('privacy', () {
      mutation(
        'setPrivacyMode stores the mode',
        act: (cubit) => cubit.setPrivacyMode(PrivacyMode.offlineOnly),
        expected: const AppSettings(privacyMode: PrivacyMode.offlineOnly),
      );

      mutation(
        'approveNetworkPair appends the pair',
        initial: const AppSettings(networkPairs: ['de>en']),
        act: (cubit) => cubit.approveNetworkPair('fr>en'),
        expected: const AppSettings(networkPairs: ['de>en', 'fr>en']),
      );

      noOp(
        'approveNetworkPair ignores known and empty pairs',
        initial: const AppSettings(networkPairs: ['de>en']),
        act: (cubit) => cubit
          ..approveNetworkPair('de>en')
          ..approveNetworkPair(''),
      );

      mutation(
        'clearNetworkPairs forgets every pair',
        initial: const AppSettings(networkPairs: ['de>en']),
        act: (cubit) => cubit.clearNetworkPairs(),
        expected: const AppSettings(),
      );

      mutation(
        'consentToProvider records the provider',
        act: (cubit) => cubit.consentToProvider('p1'),
        expected: const AppSettings(consentedProviders: ['p1']),
      );

      noOp(
        'consentToProvider ignores known and empty ids',
        initial: const AppSettings(consentedProviders: ['p1']),
        act: (cubit) => cubit
          ..consentToProvider('p1')
          ..consentToProvider(''),
      );

      mutation(
        'revokeProviderConsent removes the provider',
        initial: const AppSettings(consentedProviders: ['p1', 'p2']),
        act: (cubit) => cubit.revokeProviderConsent('p1'),
        expected: const AppSettings(consentedProviders: ['p2']),
      );

      mutation(
        'setIncognito stores the flag',
        act: (cubit) => cubit.setIncognito(enabled: true),
        expected: const AppSettings(incognito: true),
      );

      mutation(
        'setSecureScreen stores the flag',
        act: (cubit) => cubit.setSecureScreen(enabled: true),
        expected: const AppSettings(secureScreen: true),
      );

      mutation(
        'setMaskPersonalData stores the flag',
        act: (cubit) => cubit.setMaskPersonalData(enabled: false),
        expected: const AppSettings(maskPersonalData: false),
      );

      mutation(
        'setFallbackToDuckDuckGo stores the flag',
        act: (cubit) => cubit.setFallbackToDuckDuckGo(enabled: true),
        expected: const AppSettings(fallbackToDuckDuckGo: true),
      );

      mutation(
        'setLiveEngine stores the engine',
        act: (cubit) => cubit.setLiveEngine('ai:a'),
        expected: const AppSettings(liveEngineId: 'ai:a'),
      );

      mutation(
        'setLiveEngine(null) goes back to the offline engine',
        initial: const AppSettings(liveEngineId: 'ai:a'),
        act: (cubit) => cubit.setLiveEngine(null),
        expected: const AppSettings(),
      );

      mutation(
        'setTapToLookUp stores the flag',
        act: (cubit) => cubit.setTapToLookUp(enabled: false),
        expected: const AppSettings(tapToLookUp: false),
      );

      mutation(
        'setHighlightSpokenWord stores the flag',
        act: (cubit) => cubit.setHighlightSpokenWord(enabled: false),
        expected: const AppSettings(highlightSpokenWord: false),
      );

      mutation(
        'setOfflineAppShell stores the flag',
        act: (cubit) => cubit.setOfflineAppShell(enabled: false),
        expected: const AppSettings(offlineAppShell: false),
      );

      mutation(
        'setModelSource stores the source',
        act: (cubit) => cubit.setModelSource(_mirror),
        expected: const AppSettings(modelSource: _mirror),
      );

      test('keeps ModelSource.current equal to the setting', () async {
        addTearDown(() => ModelSource.current = ModelSource.platformDefault);
        final cubit = buildCubit(const AppSettings(modelSource: _mirror));
        expect(ModelSource.current, _mirror);
        cubit.setModelSource(ModelSource.defaultHosts);
        expect(ModelSource.current, ModelSource.defaultHosts);
        cubit.setModelSource(_mirror);
        expect(ModelSource.current, _mirror);
        await cubit.close();
      });

      mutation(
        'setHttpProxy stores the trimmed proxy',
        act: (cubit) => cubit.setHttpProxy(' 127.0.0.1:8118 '),
        expected: const AppSettings(httpProxy: '127.0.0.1:8118'),
      );

      mutation(
        'setHttpProxy clears the proxy when blank',
        initial: const AppSettings(httpProxy: '127.0.0.1:8118'),
        act: (cubit) => cubit.setHttpProxy('  '),
        expected: const AppSettings(),
      );
    });

    group('history retention', () {
      mutation(
        'setHistoryRetention stores the retention',
        act: (cubit) => cubit.setHistoryRetention(HistoryRetention.week),
        expected: const AppSettings(historyRetention: HistoryRetention.week),
      );

      noOp(
        'setHistoryRetention ignores the current retention',
        act: (cubit) => cubit.setHistoryRetention(HistoryRetention.forever),
      );
    });

    group('quality modes', () {
      mutation(
        'setQualityEngines sets both engines',
        act: (cubit) =>
            cubit.setQualityEngines(fast: 'mozhi:google', best: 'ai:a'),
        expected: const AppSettings(
          fastEngineId: 'mozhi:google',
          bestEngineId: 'ai:a',
        ),
      );

      mutation(
        'setQualityEngines clears the engines that are not given',
        initial: const AppSettings(
          fastEngineId: 'mozhi:google',
          bestEngineId: 'ai:a',
        ),
        act: (cubit) => cubit.setQualityEngines(best: 'ai:a'),
        expected: const AppSettings(bestEngineId: 'ai:a'),
      );

      mutation(
        'setQualityEngines() clears both engines',
        initial: const AppSettings(
          fastEngineId: 'mozhi:google',
          bestEngineId: 'ai:a',
        ),
        act: (cubit) => cubit.setQualityEngines(),
        expected: const AppSettings(),
      );

      mutation(
        'setQualityMode remembers the mode',
        act: (cubit) => cubit.setQualityMode(QualityMode.best),
        expected: const AppSettings(qualityMode: QualityMode.best),
      );

      noOp(
        'setQualityMode ignores the current mode',
        initial: const AppSettings(qualityMode: QualityMode.fast),
        act: (cubit) => cubit.setQualityMode(QualityMode.fast),
      );
    });

    group('recent language pairs', () {
      const autoToEnglish = LanguagePair(
        source: Language.auto,
        target: _english,
      );
      const frenchToGerman = LanguagePair(source: _french, target: _german);

      List<LanguagePair> pairs(int count) => [
        for (final language in _languages(count))
          LanguagePair(source: _french, target: language),
      ];

      mutation(
        'recordPair pushes the pair to the front',
        initial: const AppSettings(recentPairs: [autoToEnglish]),
        act: (cubit) => cubit.recordPair(_french, _german),
        expected: const AppSettings(
          recentPairs: [frenchToGerman, autoToEnglish],
        ),
      );

      mutation(
        'recordPair keeps an auto source',
        act: (cubit) => cubit.recordPair(Language.auto, _english),
        expected: const AppSettings(recentPairs: [autoToEnglish]),
      );

      mutation(
        'recordPair moves an existing pair to the front',
        initial: const AppSettings(
          recentPairs: [autoToEnglish, frenchToGerman],
        ),
        act: (cubit) => cubit.recordPair(_french, _german),
        expected: const AppSettings(
          recentPairs: [frenchToGerman, autoToEnglish],
        ),
      );

      mutation(
        'recordPair treats reversed pairs as different pairs',
        initial: const AppSettings(recentPairs: [frenchToGerman]),
        act: (cubit) => cubit.recordPair(_german, _french),
        expected: const AppSettings(
          recentPairs: [
            LanguagePair(source: _german, target: _french),
            frenchToGerman,
          ],
        ),
      );

      mutation(
        'recordPair keeps at most eight pairs',
        initial: AppSettings(recentPairs: pairs(8)),
        act: (cubit) => cubit.recordPair(Language.auto, _english),
        expected: AppSettings(recentPairs: [autoToEnglish, ...pairs(7)]),
      );

      mutation(
        'recordPair stores custom targets',
        act: (cubit) =>
            cubit.recordPair(_english, const Language.custom('Pirate')),
        expected: const AppSettings(
          recentPairs: [
            LanguagePair(source: _english, target: Language.custom('Pirate')),
          ],
        ),
      );

      noOp(
        'recordPair ignores an auto target',
        act: (cubit) => cubit.recordPair(_french, Language.auto),
      );

      noOp(
        'recordPair ignores a pair of the same language',
        act: (cubit) => cubit.recordPair(_french, _french),
      );

      noOp(
        'recordPair ignores the current most recent pair',
        initial: const AppSettings(
          recentPairs: [frenchToGerman, autoToEnglish],
        ),
        act: (cubit) => cubit.recordPair(_french, _german),
      );

      mutation(
        'clearRecentPairs forgets every pair',
        initial: const AppSettings(
          recentPairs: [frenchToGerman, autoToEnglish],
        ),
        act: (cubit) => cubit.clearRecentPairs(),
        expected: const AppSettings(),
      );

      noOp(
        'clearRecentPairs does nothing without pairs',
        act: (cubit) => cubit.clearRecentPairs(),
      );
    });

    group('extra targets', () {
      mutation(
        'setExtraTargets saves the languages in order',
        initial: const AppSettings(extraTargets: [_english]),
        act: (cubit) => cubit.setExtraTargets(const [_german, _french]),
        expected: const AppSettings(extraTargets: [_german, _french]),
      );

      mutation(
        'setExtraTargets drops auto and duplicates and keeps at most four',
        act: (cubit) => cubit.setExtraTargets([
          Language.auto,
          _german,
          _german,
          ..._languages(5),
        ]),
        expected: AppSettings(extraTargets: [_german, ..._languages(3)]),
      );

      mutation(
        'setExtraTargets keeps custom languages',
        act: (cubit) =>
            cubit.setExtraTargets(const [Language.custom('Pirate')]),
        expected: const AppSettings(extraTargets: [Language.custom('Pirate')]),
      );

      mutation(
        'setExtraTargets clears the languages',
        initial: const AppSettings(extraTargets: [_german, _french]),
        act: (cubit) => cubit.setExtraTargets(const []),
        expected: const AppSettings(),
      );

      noOp(
        'setExtraTargets does nothing when the languages are the same',
        initial: const AppSettings(extraTargets: [_german, _french]),
        act: (cubit) =>
            cubit.setExtraTargets(const [_german, Language.auto, _french]),
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
