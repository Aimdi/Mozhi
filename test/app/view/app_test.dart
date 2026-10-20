import 'dart:async';

import 'package:flutter_bloc/flutter_bloc.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:go_router/go_router.dart';
import 'package:material_ui/material_ui.dart';
import 'package:mocktail/mocktail.dart';
import 'package:mozhi/app/app.dart';
import 'package:mozhi/app/fallback_key_value_store.dart';
import 'package:mozhi/app/view/top_level_actions.dart';
import 'package:mozhi/core/key_value_store.dart';
import 'package:mozhi/history/models/history_entry.dart';
import 'package:mozhi/l10n/l10n.dart';
import 'package:mozhi/onboarding/view/onboarding_page.dart';
import 'package:mozhi/platform/shared_text_service.dart';
import 'package:mozhi/presets/cubit/glossary_cubit.dart';
import 'package:mozhi/presets/cubit/presets_cubit.dart';
import 'package:mozhi/quick_translate/view/quick_translate_sheet.dart';
import 'package:mozhi/settings/cubit/settings_cubit.dart';
import 'package:mozhi/settings/models/app_languages.dart';
import 'package:mozhi/settings/models/app_settings.dart';
import 'package:mozhi/translate/cubit/translate_cubit.dart';
import 'package:mozhi/translate/view/translate_page.dart';
import 'package:mozhi/usage/data/usage_tracker.dart';
import 'package:mozhi/usage/models/models.dart';
import 'package:mozhi/voice/speech_input_service.dart';
import 'package:translation_repository/translation_repository.dart';

import '../mocks.dart';

/// Secure storage that is not available.
class _BrokenStore implements KeyValueStore {
  @override
  Future<String?> read(String key) async => throw StateError('no keyring');

  @override
  Future<void> write(String key, String value) async =>
      throw StateError('no keyring');

  @override
  Future<void> delete(String key) async => throw StateError('no keyring');
}

void main() {
  setUpAll(() {
    registerAppFallbacks();
    registerFallbackValue(const AppSettings());
    registerFallbackValue(
      HistoryEntry(
        id: 'h',
        text: '',
        translation: '',
        source: Language.auto,
        target: Language.auto,
        engineId: '',
        engineName: '',
        createdAt: DateTime(2026),
      ),
    );
  });

  group('App', () {
    late TestEnvironment env;
    late StreamController<SharedText> sharedTexts;

    setUp(() {
      env = TestEnvironment();
      sharedTexts = StreamController<SharedText>.broadcast();
      when(() => env.sharedTextService.texts)
          .thenAnswer((_) => sharedTexts.stream);
      when(() => env.sharedTextService.returnResult(any()))
          .thenAnswer((_) async {});
      when(() => env.settingsRepository.save(any())).thenAnswer((_) async {});
      when(env.historyRepository.load).thenAnswer((_) async => const []);
      when(
        () => env.historyRepository.add(any()),
      ).thenAnswer((i) async => [i.positionalArguments.first as HistoryEntry]);
      when(
        () => env.translationRepository.updateConfiguration(
          instances: any(named: 'instances'),
          providers: any(named: 'providers'),
        ),
      ).thenReturn(null);
    });

    tearDown(() => sharedTexts.close());

    Future<void> pumpApp(
      WidgetTester tester, {
      AppSettings? settings,
      KeyValueStore? secrets,
    }) async {
      tester.view.physicalSize = const Size(400, 900);
      tester.view.devicePixelRatio = 1;
      addTearDown(tester.view.reset);
      await tester.pumpWidget(
        App(
          dependencies: settings == null
              ? env.dependencies(secrets: secrets)
              : env.dependencies(settings: settings, secrets: secrets),
        ),
      );
      await tester.pump();
      await tester.pump(const Duration(milliseconds: 100));
    }

    BuildContext shellContext(WidgetTester tester) =>
        tester.element(find.byType(AppShell));

    TranslateCubit translateCubit(WidgetTester tester) =>
        shellContext(tester).read<TranslateCubit>();

    testWidgets('renders the translate tab with the app shell', (tester) async {
      await pumpApp(tester);

      expect(find.byType(MaterialApp), findsOneWidget);
      expect(find.byType(AppShell), findsOneWidget);
      expect(find.byType(TranslatePage), findsOneWidget);
      final app = tester.widget<MaterialApp>(find.byType(MaterialApp));
      expect(app.themeMode, ThemeMode.system);
      expect(app.theme?.useMaterial3, isTrue);
      expect(app.darkTheme?.brightness, Brightness.dark);
    });

    testWidgets('loads history and engines on start', (tester) async {
      await pumpApp(tester);

      verify(env.historyRepository.load).called(1);
      verify(() => env.translationRepository.getEngines()).called(1);
      final translate = shellContext(tester).read<TranslateCubit>();
      expect(translate.state.enginesStatus, EnginesStatus.ready);
      expect(translate.state.engine, testEngines.first);
    });

    testWidgets('reads the history only after the first frame', (tester) async {
      bool? shellBuilt;
      when(env.historyRepository.load).thenAnswer((_) async {
        shellBuilt = find.byType(AppShell).evaluate().isNotEmpty;
        return const [];
      });

      await pumpApp(tester);

      expect(shellBuilt, isTrue);
      verify(env.historyRepository.load).called(1);
    });

    testWidgets('follows appearance settings', (tester) async {
      await pumpApp(
        tester,
        settings: const AppSettings(
          instances: [testInstance],
          dynamicColor: false,
          onboardingComplete: true,
        ),
      );

      shellContext(tester).read<SettingsCubit>().setThemeMode(ThemeMode.dark);
      // Settings changes reach the MaterialApp within two frames.
      await tester.pump();
      await tester.pump();

      final app = tester.widget<MaterialApp>(find.byType(MaterialApp));
      expect(app.themeMode, ThemeMode.dark);
      expect(app.darkTheme?.colorScheme.surface, Colors.black);
      verifyNever(
        () => env.translationRepository.updateConfiguration(
          instances: any(named: 'instances'),
          providers: any(named: 'providers'),
        ),
      );
    });

    testWidgets('pushes instance and provider changes to the repository', (
      tester,
    ) async {
      await pumpApp(tester);
      const instance = MozhiInstance(url: 'http://lan.test:3000');
      const provider = AiProviderConfig(
        id: 'local',
        name: 'Local',
        provider: LlmProvider.ollama,
        baseUrl: 'http://lan.test:11434',
        model: 'qwen3',
      );

      shellContext(tester).read<SettingsCubit>().addInstance(instance);
      await tester.pump();

      verify(
        () => env.translationRepository.updateConfiguration(
          instances: const [testInstance, instance],
          providers: const [],
        ),
      ).called(1);
      verify(() => env.translationRepository.getEngines(refresh: true))
          .called(1);

      shellContext(tester).read<SettingsCubit>().saveProvider(provider);
      await tester.pump();

      verify(
        () => env.translationRepository.updateConfiguration(
          instances: const [testInstance, instance],
          providers: const [provider],
        ),
      ).called(1);
      verify(() => env.translationRepository.getEngines(refresh: true))
          .called(1);
    });

    testWidgets('pushes the privacy settings before anything starts', (
      tester,
    ) async {
      await pumpApp(
        tester,
        settings: const AppSettings(
          onboardingComplete: true,
          instances: [testInstance],
          privacyMode: PrivacyMode.offlineOnly,
          networkPairs: ['de>en'],
          consentedProviders: ['claude'],
        ),
      );
      verify(
        () => env.translationRepository.updatePrivacy(
          mode: PrivacyMode.offlineOnly,
          approvedPairs: const ['de>en'],
          consentedProviders: const ['claude'],
        ),
      ).called(1);
    });

    testWidgets('pushes privacy changes, reloading engines on a new mode', (
      tester,
    ) async {
      await pumpApp(tester);
      clearInteractions(env.translationRepository);
      final settings = shellContext(tester).read<SettingsCubit>()
        ..approveNetworkPair('de>en');
      await tester.pump();
      verify(
        () => env.translationRepository.updatePrivacy(
          mode: settings.state.privacyMode,
          approvedPairs: const ['de>en'],
        ),
      ).called(1);
      verifyNever(() => env.translationRepository.getEngines());

      settings.setPrivacyMode(PrivacyMode.offlineOnly);
      await tester.pump();
      verify(
        () => env.translationRepository.updatePrivacy(
          mode: PrivacyMode.offlineOnly,
          approvedPairs: const ['de>en'],
        ),
      ).called(1);
      verify(() => env.translationRepository.getEngines()).called(1);
    });

    testWidgets('translates text shared at launch', (tester) async {
      when(env.sharedTextService.initialText)
          .thenAnswer((_) async => const SharedText('hola'));

      await pumpApp(tester);

      final translate = shellContext(tester).read<TranslateCubit>();
      expect(translate.state.input, 'hola');
      verify(() => env.translationRepository.translate(any(), any())).called(1);
    });

    testWidgets('brings shared text to the translate tab', (tester) async {
      await pumpApp(tester);
      // History, a page above the tabs.
      await tester.tap(find.byKey(TopLevelActions.historyKey));
      await tester.pump();
      await tester.pump(const Duration(seconds: 1));
      expect(find.byType(TranslatePage).hitTestable(), findsNothing);

      sharedTexts.add(const SharedText('bonjour'));
      await tester.pump();
      await tester.pump(const Duration(milliseconds: 400));

      expect(find.byType(TranslatePage).hitTestable(), findsOneWidget);
      expect(
        shellContext(tester).read<TranslateCubit>().state.input,
        'bonjour',
      );
    });

    group('selected text (PROCESS_TEXT)', () {
      setUp(() {
        when(() => env.translationRepository.translate(any(), any()))
            .thenAnswer(
              (_) => Stream.value(
                const TranslationResult(
                  engineId: 'mozhi:google',
                  engineName: 'Google',
                  text: 'hello',
                ),
              ),
            );
        when(env.sharedTextService.initialText).thenAnswer(
          (_) async =>
              const SharedText('hola', readOnly: false, isProcessText: true),
        );
      });

      testWidgets('shows quick translate and replaces the selection', (
        tester,
      ) async {
        await pumpApp(tester);
        await tester.pump(const Duration(seconds: 1));

        expect(find.byType(QuickTranslateSheet), findsOneWidget);
        expect(translateCubit(tester).state.input, isEmpty);
        expect(find.text('hello'), findsOneWidget);

        await tester.tap(find.byKey(const Key('quick_translate_replace')));
        await tester.pump();
        await tester.pump(const Duration(seconds: 1));

        verify(() => env.sharedTextService.returnResult('hello')).called(1);
        expect(find.byType(QuickTranslateSheet), findsNothing);
      });

      testWidgets('"Open in app" moves the text to the translate tab', (
        tester,
      ) async {
        await pumpApp(tester);
        await tester.pump(const Duration(seconds: 1));

        await tester.tap(find.byKey(const Key('quick_translate_open_in_app')));
        await tester.pump();
        await tester.pump(const Duration(seconds: 1));

        expect(find.byType(QuickTranslateSheet), findsNothing);
        expect(translateCubit(tester).state.input, 'hola');
        verifyNever(() => env.sharedTextService.returnResult(any()));
      });

      testWidgets('"Translate offline" never uses a network engine', (
        tester,
      ) async {
        when(env.sharedTextService.initialText).thenAnswer(
          (_) async => const SharedText(
            'hola',
            readOnly: false,
            isProcessText: true,
            action: SharedText.translateOfflineAction,
          ),
        );
        when(() => env.translationRepository.hasOfflineEngine)
            .thenReturn(false);
        await pumpApp(tester);
        await tester.pump(const Duration(seconds: 1));

        final sheet = tester.widget<QuickTranslateSheet>(
          find.byType(QuickTranslateSheet),
        );
        expect(sheet.offlineOnly, isTrue);
        // The test app has no on-device engine: nothing is translated.
        expect(find.text('Can’t translate on this device'), findsOneWidget);
        expect(translateCubit(tester).state.input, isEmpty);
        verifyNever(() => env.translationRepository.translate(any(), any()));
      });
    });

    testWidgets('does not auto-run AI translations of shared text while '
        'instant AI translation is off', (tester) async {
      const provider = AiProviderConfig(
        id: 'cloud',
        name: 'Cloud',
        provider: LlmProvider.openAiCompatible,
        baseUrl: 'https://api.example.test/v1',
        model: 'm',
      );
      const aiEngine = TranslationEngine(
        id: 'ai:cloud',
        kind: EngineKind.ai,
        name: 'Cloud',
        providerId: 'cloud',
      );
      when(
        () => env.translationRepository.getEngines(
          refresh: any(named: 'refresh'),
        ),
      ).thenAnswer((_) async => const [aiEngine]);
      when(env.sharedTextService.initialText)
          .thenAnswer((_) async => const SharedText('hola'));

      await pumpApp(
        tester,
        settings: const AppSettings(
          instances: [testInstance],
          providers: [provider],
          engineId: 'ai:cloud',
          instantTranslateAi: false,
          onboardingComplete: true,
        ),
      );

      expect(translateCubit(tester).state.input, 'hola');
      verifyNever(() => env.translationRepository.translate(any(), any()));
    });

    testWidgets('shows the onboarding on the first run', (tester) async {
      await pumpApp(
        tester,
        settings: const AppSettings(instances: [testInstance]),
      );
      await tester.pump(const Duration(seconds: 1));

      expect(find.byType(OnboardingPage), findsOneWidget);
      expect(find.byType(AppShell), findsNothing);
    });

    testWidgets('warns once when API keys are kept in memory', (tester) async {
      final secrets = FallbackKeyValueStore(_BrokenStore());
      await secrets.probe();

      await pumpApp(tester, secrets: secrets);

      expect(
        find.text(
          "API keys can't be stored securely on this device; they will be "
          'kept only for this session.',
        ),
        findsOneWidget,
      );
    });

    testWidgets('says nothing when secure storage works', (tester) async {
      await pumpApp(tester);

      expect(find.byType(SnackBar), findsNothing);
    });

    testWidgets('provides the app-wide services', (tester) async {
      await pumpApp(tester);
      final context = shellContext(tester);

      expect(context.read<SpeechInputService>(), env.speechInputService);
      expect(context.read<OfflineTranslator>(), env.offlineTranslator);
      expect(context.read<UsageTracker>(), env.usageTracker);
      expect(context.read<KeyValueStore>(), same(env.preferences));
      expect(context.read<PresetsCubit>(), isA<PresetsCubit>());
      expect(context.read<GlossaryCubit>(), isA<GlossaryCubit>());
    });

    testWidgets('shows usage budget warnings with the provider name', (
      tester,
    ) async {
      const provider = AiProviderConfig(
        id: 'cloud',
        name: 'Cloud AI',
        provider: LlmProvider.openAiCompatible,
        baseUrl: 'https://api.example.test/v1',
        model: 'm',
      );
      await pumpApp(
        tester,
        settings: const AppSettings(
          instances: [testInstance],
          providers: [provider],
          onboardingComplete: true,
        ),
      );

      await tester.runAsync(() async {
        await env.usageTracker.setBudget(
          'cloud',
          const UsageBudget(monthlyChars: 10),
        );
        await env.usageTracker.record('cloud', 10, 10);
        await env.usageTracker.setBudget(
          'other',
          const UsageBudget(monthlyChars: 10),
        );
      });
      await tester.pump();

      expect(
        find.text('Cloud AI has reached its monthly budget'),
        findsOneWidget,
      );

      await tester.runAsync(() => env.usageTracker.record('other', 10, 10));
      await tester.pump();

      expect(
        find.text('Your AI provider has reached its monthly budget'),
        findsOneWidget,
      );
    });

    testWidgets('opens translate links', (tester) async {
      await pumpApp(tester);

      GoRouter.of(shellContext(tester))
          .go(AppRoutes.translateText(text: 'hallo', to: 'en'));
      await tester.pump();
      await tester.pump(const Duration(milliseconds: 100));

      final translate = shellContext(tester).read<TranslateCubit>();
      expect(translate.state.input, 'hallo');
      expect(
        GoRouter.of(shellContext(tester))
            .routerDelegate
            .currentConfiguration
            .uri
            .toString(),
        AppRoutes.translate,
      );
    });

    group('general settings', () {
      String location(WidgetTester tester) =>
          GoRouter.of(shellContext(tester))
              .routerDelegate
              .currentConfiguration
              .uri
              .toString();

      testWidgets('shows the app in the chosen language', (tester) async {
        await pumpApp(
          tester,
          settings: const AppSettings(
            instances: [testInstance],
            onboardingComplete: true,
            appLocale: 'de',
          ),
        );

        final app = tester.widget<MaterialApp>(find.byType(MaterialApp));
        expect(app.locale, const Locale('de'));
        expect(app.localizationsDelegates, appLocalizationsDelegates);
        expect(tester.takeException(), isNull);
        final context = shellContext(tester);
        expect(Localizations.localeOf(context), const Locale('de'));
        expect(context.l10n.navTranslate, 'Übersetzen');
        // material_ui's own texts are German too (no crash in the
        // navigation bar).
        expect(MaterialLocalizations.of(context).backButtonTooltip, 'Zurück');
        expect(
          find.byWidgetPredicate(
            (widget) => widget is Tooltip && widget.message == 'Übersetzen',
          ),
          findsOneWidget,
        );
      });

      testWidgets('switches the app language at once', (tester) async {
        await pumpApp(tester);
        expect(shellContext(tester).l10n.navDictionary, 'Dictionary');

        shellContext(tester).read<SettingsCubit>().setAppLocale('ja');
        await tester.pump();
        await tester.pump();
        expect(shellContext(tester).l10n.navDictionary, '辞書');

        shellContext(tester).read<SettingsCubit>().setAppLocale(null);
        await tester.pump();
        await tester.pump();
        expect(shellContext(tester).l10n.navDictionary, 'Dictionary');
      });

      testWidgets('follows the device for an unknown stored language', (
        tester,
      ) async {
        await pumpApp(
          tester,
          settings: const AppSettings(
            instances: [testInstance],
            onboardingComplete: true,
            appLocale: 'sv',
          ),
        );

        final app = tester.widget<MaterialApp>(find.byType(MaterialApp));
        expect(app.locale, isNull);
        expect(
          app.localeListResolutionCallback,
          AppLanguages.resolveDeviceLocales,
        );
        expect(Localizations.localeOf(shellContext(tester)).languageCode, 'en');
      });

      testWidgets('opens on the first tab of the order', (tester) async {
        await pumpApp(
          tester,
          settings: const AppSettings(
            instances: [testInstance],
            onboardingComplete: true,
            tabOrder: [
              AppTab.dictionary,
              AppTab.translate,
              AppTab.proofread,
              AppTab.conversation,
            ],
          ),
        );
        await tester.pump(const Duration(milliseconds: 100));

        expect(location(tester), AppRoutes.dictionary);
        final bar = tester.widget<NavigationBar>(find.byType(NavigationBar));
        expect(bar.selectedIndex, 0);
        expect(
          (bar.destinations.first as NavigationDestination).label,
          'Dictionary',
        );
      });

      testWidgets('opens on the translate tab by default', (tester) async {
        await pumpApp(tester);
        expect(location(tester), AppRoutes.translate);
      });

      testWidgets('stays on the translate tab when started there', (
        tester,
      ) async {
        // The home-screen widget's Type button (mozhi://translate), or a
        // reload of the web app at #/translate.
        tester.platformDispatcher.defaultRouteNameTestValue =
            AppRoutes.translate;
        addTearDown(tester.platformDispatcher.clearDefaultRouteNameTestValue);
        await pumpApp(
          tester,
          settings: const AppSettings(
            instances: [testInstance],
            onboardingComplete: true,
            tabOrder: [
              AppTab.dictionary,
              AppTab.translate,
              AppTab.proofread,
              AppTab.conversation,
            ],
          ),
        );
        await tester.pump(const Duration(milliseconds: 100));

        expect(location(tester), AppRoutes.translate);
      });

      testWidgets('starts in the default quality mode unless remembered', (
        tester,
      ) async {
        await pumpApp(
          tester,
          settings: const AppSettings(
            instances: [testInstance],
            onboardingComplete: true,
            fastEngineId: 'mozhi:google',
            bestEngineId: 'ai:p1',
            qualityMode: QualityMode.best,
            rememberQuality: false,
          ),
        );

        final settings = shellContext(tester).read<SettingsCubit>().state;
        expect(settings.qualityMode, QualityMode.fast);
        expect(settings.bestEngineId, 'ai:p1');
      });

      testWidgets('keeps the last quality mode when remembered', (
        tester,
      ) async {
        await pumpApp(
          tester,
          settings: const AppSettings(
            instances: [testInstance],
            onboardingComplete: true,
            fastEngineId: 'mozhi:google',
            bestEngineId: 'ai:p1',
            qualityMode: QualityMode.best,
          ),
        );

        expect(
          shellContext(tester).read<SettingsCubit>().state.qualityMode,
          QualityMode.best,
        );
      });
    });

    testWidgets('closes its cubits when removed', (tester) async {
      await pumpApp(tester);
      final translate = shellContext(tester).read<TranslateCubit>();
      final settings = shellContext(tester).read<SettingsCubit>();

      await tester.pumpWidget(const SizedBox());
      await tester.pump();

      expect(translate.isClosed, isTrue);
      expect(settings.isClosed, isTrue);
      expect(env.offlineTranslator.disposed, isTrue);
      verify(env.speechService.dispose).called(1);
    });
  });

  group('engineConfigurationChanged', () {
    const base = AppSettings(instances: [testInstance]);
    const provider = AiProviderConfig(
      id: 'p',
      name: 'P',
      provider: LlmProvider.openAiCompatible,
      baseUrl: 'http://localhost:1234/v1',
      model: 'm',
    );

    test('is false for unrelated changes', () {
      expect(
        engineConfigurationChanged(
          base,
          const AppSettings(
            instances: [testInstance],
            themeMode: ThemeMode.dark,
            saveHistory: false,
          ),
        ),
        isFalse,
      );
    });

    test('detects added, removed, reordered or relabelled instances', () {
      const other = MozhiInstance(url: 'http://other.test');
      bool changed(List<MozhiInstance> instances) => engineConfigurationChanged(
        const AppSettings(instances: [testInstance, other]),
        AppSettings(instances: instances),
      );

      expect(changed(const [testInstance, other]), isFalse);
      expect(changed(const [testInstance]), isTrue);
      expect(changed(const [other, testInstance]), isTrue);
      expect(
        changed(const [
          MozhiInstance(url: 'http://mozhi.test', label: 'Renamed'),
          other,
        ]),
        isTrue,
      );
    });

    test('detects provider changes including headers', () {
      bool changed(List<AiProviderConfig> providers) =>
          engineConfigurationChanged(
            const AppSettings(providers: [provider]),
            AppSettings(providers: providers),
          );

      expect(changed(const [provider]), isFalse);
      expect(changed(const []), isTrue);
      expect(changed([provider.copyWith(model: 'other')]), isTrue);
      expect(changed([provider.copyWith(enabled: false)]), isTrue);
      expect(
        changed([
          provider.copyWith(headers: {'X-Key': '1'}),
        ]),
        isTrue,
      );
    });
  });

  group('privacyChanged', () {
    test('compares the mode, approved pairs and consented providers', () {
      const base = AppSettings(networkPairs: ['de>en']);
      expect(
        privacyChanged(base, const AppSettings(networkPairs: ['de>en'])),
        isFalse,
      );
      expect(
        privacyChanged(
          base,
          const AppSettings(networkPairs: ['de>en'], saveHistory: false),
        ),
        isFalse,
      );
      expect(
        privacyChanged(
          base,
          const AppSettings(
            networkPairs: ['de>en'],
            privacyMode: PrivacyMode.online,
          ),
        ),
        isTrue,
      );
      expect(privacyChanged(base, const AppSettings()), isTrue);
      expect(
        privacyChanged(
          base,
          const AppSettings(
            networkPairs: ['de>en'],
            consentedProviders: ['claude'],
          ),
        ),
        isTrue,
      );
    });
  });

  group('appearanceChanged', () {
    test('compares only appearance settings', () {
      const base = AppSettings();
      expect(appearanceChanged(base, const AppSettings()), isFalse);
      expect(
        appearanceChanged(base, const AppSettings(saveHistory: false)),
        isFalse,
      );
      expect(
        appearanceChanged(base, const AppSettings(themeMode: ThemeMode.light)),
        isTrue,
      );
      expect(
        appearanceChanged(base, const AppSettings(dynamicColor: false)),
        isTrue,
      );
      expect(
        appearanceChanged(base, const AppSettings(pureBlack: false)),
        isTrue,
      );
      expect(appearanceChanged(base, const AppSettings(seedColor: 1)), isTrue);
      expect(
        appearanceChanged(base, const AppSettings(appLocale: 'de')),
        isTrue,
      );
    });
  });
}
