import 'dart:async';

import 'package:flutter_bloc/flutter_bloc.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:material_ui/material_ui.dart';
import 'package:mocktail/mocktail.dart';
import 'package:mozhi/app/app.dart';
import 'package:mozhi/history/models/history_entry.dart';
import 'package:mozhi/platform/shared_text_service.dart';
import 'package:mozhi/settings/cubit/settings_cubit.dart';
import 'package:mozhi/settings/models/app_settings.dart';
import 'package:mozhi/translate/cubit/translate_cubit.dart';
import 'package:mozhi/translate/view/translate_page.dart';
import 'package:translation_repository/translation_repository.dart';

import '../mocks.dart';

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

    AppDependencies dependencies({
      AppSettings settings = const AppSettings(instances: [testInstance]),
    }) => AppDependencies(
      translationRepository: env.translationRepository,
      settingsRepository: env.settingsRepository,
      historyRepository: env.historyRepository,
      speechService: env.speechService,
      sharedTextService: env.sharedTextService,
      settings: settings,
    );

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

    Future<void> pumpApp(WidgetTester tester, {AppSettings? settings}) async {
      tester.view.physicalSize = const Size(400, 900);
      tester.view.devicePixelRatio = 1;
      addTearDown(tester.view.reset);
      await tester.pumpWidget(
        App(
          dependencies: settings == null
              ? dependencies()
              : dependencies(settings: settings),
        ),
      );
      await tester.pump();
      await tester.pump(const Duration(milliseconds: 100));
    }

    BuildContext shellContext(WidgetTester tester) =>
        tester.element(find.byType(AppShell));

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

    testWidgets('follows appearance settings', (tester) async {
      await pumpApp(
        tester,
        settings: const AppSettings(
          instances: [testInstance],
          dynamicColor: false,
          pureBlack: true,
        ),
      );

      shellContext(tester).read<SettingsCubit>().setThemeMode(ThemeMode.dark);
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
      await tester.tap(find.text('History'));
      await tester.pump();
      await tester.pump(const Duration(milliseconds: 400));
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

    testWidgets('offers to replace selected text once translated', (
      tester,
    ) async {
      when(() => env.translationRepository.translate(any(), any())).thenAnswer(
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

      await pumpApp(tester);
      await tester.pump(const Duration(milliseconds: 750));

      expect(find.text('Translation ready'), findsOneWidget);
      await tester.tap(find.text('Replace text'));
      await tester.pump();

      verify(() => env.sharedTextService.returnResult('hello')).called(1);
    });

    testWidgets('closes its cubits when removed', (tester) async {
      await pumpApp(tester);
      final translate = shellContext(tester).read<TranslateCubit>();
      final settings = shellContext(tester).read<SettingsCubit>();

      await tester.pumpWidget(const SizedBox());
      await tester.pump();

      expect(translate.isClosed, isTrue);
      expect(settings.isClosed, isTrue);
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
        appearanceChanged(base, const AppSettings(pureBlack: true)),
        isTrue,
      );
      expect(appearanceChanged(base, const AppSettings(seedColor: 1)), isTrue);
    });
  });
}
