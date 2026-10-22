import 'dart:async';

import 'package:bloc_test/bloc_test.dart';
import 'package:flutter_bloc/flutter_bloc.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:material_ui/material_ui.dart';
import 'package:mocktail/mocktail.dart';
import 'package:mozhi/core/widgets/x_ui.dart';
import 'package:mozhi/l10n/l10n.dart';
import 'package:mozhi/offline/offline.dart' show OfflineEngineBadge;
import 'package:mozhi/translate/translate.dart';
import 'package:mozhi/translate/widgets/widgets.dart';
import 'package:translation_repository/translation_repository.dart';

import '../../helpers/pump_app.dart';
import '../helpers/helpers.dart';

class _MockRepository extends Mock implements TranslationRepository;

/// DeepL API with the user's own key (a cloud service).
const _deeplApi = TranslationEngine(
  id: 'mt:deepl',
  kind: EngineKind.mt,
  name: 'DeepL API',
  subtitle: 'api-free.deepl.com',
  providerId: 'deepl',
  mtService: MtService.deepl,
);

/// A LibreTranslate server on the LAN.
const _libre = TranslationEngine(
  id: 'mt:libre',
  kind: EngineKind.mt,
  name: 'LibreTranslate',
  subtitle: '192.168.1.20',
  providerId: 'libre',
  isLocal: true,
  mtService: MtService.libreTranslate,
);

const _offline = TranslationEngine(
  id: TranslationEngine.offlineId,
  kind: EngineKind.offline,
  name: 'Offline (on-device)',
  isLocal: true,
);

void main() {
  setUpAll(() {
    registerTranslateFallbacks();
    registerFallbackValue(QualityMode.off);
  });

  group('EngineSelectorButton', () {
    testWidgets('shows the current engine, without its details', (
      tester,
    ) async {
      final harness = TranslateHarness();
      await harness.pump(tester, child: const EngineSelectorButton());
      expect(find.text('DeepL'), findsOneWidget);
      // A model id or host stays in the sheet.
      expect(find.text('mozhi.example.org'), findsNothing);
      expect(find.byTooltip('Choose translation engine'), findsOneWidget);
      // An interactive outline: the 3:1 control outline, not a hairline.
      final button = tester.widget<TextButton>(
        find.byKey(const Key('translate_engine_selector')),
      );
      final shape = button.style!.shape!.resolve({})! as StadiumBorder;
      expect(
        shape.side.color,
        Theme.of(tester.element(find.byType(TextButton))).colorScheme.outline,
      );
    });

    testWidgets('is quieter, secondary text once Fast and Best are set up', (
      tester,
    ) async {
      final harness = TranslateHarness(
        state: readyState(engine: google).copyWith(
          qualityMode: QualityMode.fast,
          fastEngine: () => google,
          bestEngine: () => claude,
        ),
      );
      await harness.pump(tester, child: const EngineSelectorButton());
      final name = tester.widget<Text>(
        find.byKey(const Key('translate_engine_selector_name')),
      );
      expect(name.data, 'Google');
      final context = tester.element(
        find.byKey(const Key('translate_engine_selector_name')),
      );
      expect(name.style?.color, AppPalette.of(context).secondaryText);
      expect(name.style?.fontWeight, FontWeight.w500);
    });

    testWidgets('follows engine changes', (tester) async {
      final harness = TranslateHarness();
      final states = StreamController<TranslateState>();
      addTearDown(states.close);
      whenListen(harness.translate, states.stream, initialState: readyState());
      await harness.pump(tester, child: const EngineSelectorButton());
      expect(find.text('DeepL'), findsOneWidget);

      states.add(readyState(engine: _deeplApi));
      await tester.pump();
      expect(find.text('DeepL API'), findsOneWidget);
      expect(find.text('api-free.deepl.com'), findsNothing);
      expect(find.byIcon(Icons.translate), findsOneWidget);

      // Only the list changes (e.g. a provider was removed).
      states.add(readyState(engine: _deeplApi).copyWith(engines: const []));
      await tester.pump();
      await tester.pump();
      final button = tester.widget<TextButton>(
        find.byKey(const Key('translate_engine_selector')),
      );
      expect(button.onPressed, isNull);
    });

    testWidgets('is disabled without engines', (tester) async {
      final harness = TranslateHarness(
        state: const TranslateState(enginesStatus: EnginesStatus.loading),
      );
      await harness.pump(tester, child: const EngineSelectorButton());
      expect(find.text('Translation engine'), findsOneWidget);
      final button = tester.widget<TextButton>(
        find.byKey(const Key('translate_engine_selector')),
      );
      expect(button.onPressed, isNull);
    });
  });

  group('EngineSheet', () {
    Future<TranslateHarness> open(
      WidgetTester tester, {
      List<TranslationEngine>? engines,
    }) async {
      final harness = TranslateHarness(
        state: engines == null ? null : readyState().copyWith(engines: engines),
      );
      await harness.pump(
        tester,
        child: const EngineSelectorButton(),
        size: const Size(800, 1200),
      );
      await tester.tap(find.byKey(const Key('translate_engine_selector')));
      await tester.pumpAndSettle();
      return harness;
    }

    testWidgets('groups engines with privacy badges', (tester) async {
      await open(tester);
      expect(
        find.text('Mozhi engines (via mozhi.example.org)'),
        findsOneWidget,
      );
      expect(find.text('AI models'), findsOneWidget);
      // The instance's badge once, in its header.
      expect(find.text('Public server'), findsOneWidget);
      expect(
        tester.getTopLeft(find.text('Public server')).dy,
        lessThan(tester.getTopLeft(find.text('Google')).dy),
      );
      // AI models go to different places: a badge on each.
      expect(find.text('Cloud'), findsOneWidget);
      expect(find.text('Self-hosted'), findsOneWidget);
      // The model id stays in the sheet, after what the engine is for.
      expect(
        find.text(
          'Follows tone, context and your other options · claude-opus-5-5',
        ),
        findsOneWidget,
      );
      expect(find.text('Good for European languages'), findsOneWidget);
      expect(find.text('Covers the most languages'), findsOneWidget);
      expect(find.byIcon(Icons.check), findsOneWidget);
    });

    Finder tile(String name) =>
        find.ancestor(of: find.text(name), matching: find.byType(ListTile));

    Finder inTile(String name, Finder matching) =>
        find.descendant(of: tile(name), matching: matching);

    double top(WidgetTester tester, Finder finder) =>
        tester.getTopLeft(finder).dy;

    testWidgets('lists translation services in their own section', (
      tester,
    ) async {
      await open(
        tester,
        engines: const [deepl, google, _deeplApi, _libre, claude, ollama],
      );

      expect(find.text('Machine translation'), findsOneWidget);
      expect(find.text('On this device'), findsNothing);
      expect(find.byType(OfflineEngineBadge), findsNothing);
      expect(find.byIcon(OfflineEngineBadge.icon), findsNothing);

      // Mozhi engines, then services, then AI models.
      final mozhiHeader = find.text('Mozhi engines (via mozhi.example.org)');
      final servicesHeader = find.text('Machine translation');
      final aiHeader = find.text('AI models');
      expect(top(tester, mozhiHeader), lessThan(top(tester, servicesHeader)));
      expect(
        top(tester, servicesHeader),
        lessThan(top(tester, find.text('DeepL API'))),
      );
      expect(
        top(tester, find.text('LibreTranslate')),
        lessThan(top(tester, aiHeader)),
      );

      // A cloud service: Cloud badge, translate icon, its host.
      expect(inTile('DeepL API', find.text('Cloud')), findsOneWidget);
      expect(inTile('DeepL API', find.byIcon(Icons.translate)), findsOne);
      expect(
        inTile(
          'DeepL API',
          find.text('Good for European languages · api-free.deepl.com'),
        ),
        findsOne,
      );
      expect(inTile('DeepL API', find.text('Self-hosted')), findsNothing);

      // A server on the LAN is self-hosted, not Offline.
      expect(inTile('LibreTranslate', find.text('Self-hosted')), findsOne);
      expect(inTile('LibreTranslate', find.byType(PrivacyBadge)), findsOne);
      expect(inTile('LibreTranslate', find.byIcon(Icons.translate)), findsOne);
      expect(
        inTile(
          'LibreTranslate',
          find.text('Open-source machine translation · 192.168.1.20'),
        ),
        findsOne,
      );
    });

    test('the machine translation header is translated in every locale', () {
      final en = lookupAppLocalizations(const Locale('en'));
      // The term the add-provider sheet groups these services under, not
      // the settings section that holds every kind of service.
      expect(en.translateMtServicesHeader, en.settingsProvidersPresetsMt);
      expect(en.translateMtServicesHeader, isNot(en.settingsSectionServices));
      for (final locale in AppLocalizations.supportedLocales) {
        if (locale.languageCode == 'en') continue;
        expect(
          lookupAppLocalizations(locale).translateMtServicesHeader,
          isNot(en.translateMtServicesHeader),
          reason: '$locale',
        );
      }
    });

    testWidgets('lists offline engines under "On this device"', (tester) async {
      await open(tester, engines: const [deepl, _deeplApi, claude, _offline]);

      expect(find.text('On this device'), findsOneWidget);
      expect(find.text('Machine translation'), findsOneWidget);
      // The section's badge, in its header.
      expect(find.byType(OfflineEngineBadge), findsOneWidget);
      expect(
        tester.getTopLeft(find.byType(OfflineEngineBadge)).dy,
        lessThan(tester.getTopLeft(find.text('Offline (on-device)')).dy),
      );
      expect(
        inTile('Offline (on-device)', find.byType(PrivacyBadge)),
        findsNothing,
      );
      expect(
        inTile('Offline (on-device)', find.byIcon(OfflineEngineBadge.icon)),
        findsWidgets,
      );
      expect(
        inTile(
          'Offline (on-device)',
          find.text('Private: your text stays on this device'),
        ),
        findsOne,
      );
      expect(
        top(tester, find.text('On this device')),
        lessThan(top(tester, find.text('Machine translation'))),
      );
      expect(
        inTile('DeepL API', find.byType(OfflineEngineBadge)),
        findsNothing,
      );
    });

    testWidgets('selecting an offline engine calls selectEngine', (
      tester,
    ) async {
      final harness = await open(tester, engines: const [deepl, _offline]);
      await tester.tap(find.text('Offline (on-device)'));
      await tester.pumpAndSettle();
      verify(() => harness.translate.selectEngine(_offline)).called(1);
    });

    testWidgets('names Mozhi engines without an instance plainly', (
      tester,
    ) async {
      const bing = TranslationEngine(
        id: 'mozhi:bing',
        kind: EngineKind.mozhi,
        name: 'Bing',
        mozhiEngine: 'bing',
      );
      await open(tester, engines: const [bing]);
      expect(find.text('Mozhi engines'), findsOneWidget);
    });

    testWidgets('quality modes link to their settings', (tester) async {
      final harness = TranslateHarness(
        state: readyState(engine: google).copyWith(
          qualityMode: QualityMode.fast,
          fastEngine: () => google,
          bestEngine: () => claude,
        ),
      );
      await harness.pump(
        tester,
        child: const EngineSelectorButton(),
        size: const Size(800, 1200),
      );
      await tester.tap(find.byKey(const Key('translate_engine_selector')));
      await tester.pumpAndSettle();
      expect(find.text('Change the Fast and Best engines'), findsOneWidget);

      await tester.tap(find.byKey(const Key('translate_quality_settings')));
      await tester.pumpAndSettle();
      verify(() => harness.router.push<void>(translateQualityLocation))
          .called(1);
    });

    group('with Fast and Best set up', () {
      Future<TranslateHarness> openModes(WidgetTester tester) async {
        final harness = TranslateHarness(
          state: readyState(engine: google).copyWith(
            qualityMode: QualityMode.fast,
            fastEngine: () => google,
            bestEngine: () => claude,
          ),
        );
        when(() => harness.translate.setQualityMode(any()))
            .thenAnswer((_) async {});
        await harness.pump(
          tester,
          child: const EngineSelectorButton(),
          size: const Size(800, 1200),
        );
        await tester.tap(find.byKey(const Key('translate_engine_selector')));
        await tester.pumpAndSettle();
        return harness;
      }

      Finder mode(String name) =>
          find.byKey(ValueKey('translate_engine_mode_$name'));

      testWidgets('starts with the modes and their engines', (tester) async {
        await openModes(tester);
        expect(find.text('Quality mode'), findsOneWidget);
        final fast = tester.widget<ListTile>(mode('fast'));
        expect(fast.selected, isTrue);
        expect(
          find.descendant(
            of: mode('fast'),
            matching: find.text('Google · Covers the most languages'),
          ),
          findsOneWidget,
        );
        expect(tester.widget<ListTile>(mode('best')).selected, isFalse);
        // The engine list waits behind "Custom engine…".
        expect(find.text('Custom engine…'), findsOneWidget);
        expect(find.text('Choose the engine Fast translates with'), findsOne);
        expect(find.text('AI models'), findsNothing);
      });

      testWidgets('choosing a mode calls setQualityMode', (tester) async {
        final harness = await openModes(tester);
        await tester.tap(mode('best'));
        await tester.pumpAndSettle();
        verify(() => harness.translate.setQualityMode(QualityMode.best))
            .called(1);
      });

      testWidgets('choosing the active mode just closes', (tester) async {
        final harness = await openModes(tester);
        await tester.tap(mode('fast'));
        await tester.pumpAndSettle();
        verifyNever(() => harness.translate.setQualityMode(any()));
      });

      testWidgets('"Custom engine…" picks the engine of the mode', (
        tester,
      ) async {
        final harness = await openModes(tester);
        await tester.tap(find.byKey(const Key('translate_engine_custom')));
        await tester.pumpAndSettle();
        expect(find.text('AI models'), findsOneWidget);
        await tester.tap(find.text('DeepL'));
        await tester.pumpAndSettle();
        verify(() => harness.translate.selectEngine(deepl)).called(1);
      });

      testWidgets('names the Best mode while it is on', (tester) async {
        final harness = TranslateHarness(
          state: readyState(engine: claude).copyWith(
            qualityMode: QualityMode.best,
            fastEngine: () => google,
            bestEngine: () => claude,
          ),
        );
        await harness.pump(
          tester,
          child: const EngineSelectorButton(),
          size: const Size(800, 1200),
        );
        await tester.tap(find.byKey(const Key('translate_engine_selector')));
        await tester.pumpAndSettle();
        expect(find.text('Choose the engine Best translates with'), findsOne);
      });
    });

    testWidgets('leaves out empty sections', (tester) async {
      await open(tester, engines: const [_deeplApi]);

      expect(find.text('Machine translation'), findsOneWidget);
      expect(find.text('Mozhi engines'), findsNothing);
      expect(find.textContaining('Mozhi engines ('), findsNothing);
      expect(find.text('AI models'), findsNothing);
      expect(find.text('On this device'), findsNothing);
    });

    testWidgets('selecting a translation service calls selectEngine', (
      tester,
    ) async {
      final harness = await open(
        tester,
        engines: const [deepl, _deeplApi, claude],
      );
      await tester.tap(find.text('DeepL API'));
      await tester.pumpAndSettle();
      verify(() => harness.translate.selectEngine(_deeplApi)).called(1);
    });

    testWidgets('selecting an engine calls selectEngine', (tester) async {
      final harness = await open(tester);
      await tester.tap(find.text('Claude'));
      await tester.pumpAndSettle();
      verify(() => harness.translate.selectEngine(claude)).called(1);
      expect(find.text('AI models'), findsNothing);
    });

    testWidgets('selecting the current engine just closes', (tester) async {
      final harness = await open(tester);
      await tester.tap(find.text('DeepL').last);
      await tester.pumpAndSettle();
      verifyNever(() => harness.translate.selectEngine(any()));
    });

    testWidgets('"Add AI provider" opens provider settings', (tester) async {
      final harness = await open(tester);
      await tester.tap(find.text('Add AI provider'));
      await tester.pumpAndSettle();
      verify(() => harness.router.push<void>('/settings/providers')).called(1);
    });

    testWidgets('"Manage instances" opens instance settings', (tester) async {
      final harness = await open(tester);
      await tester.tap(find.text('Manage instances'));
      await tester.pumpAndSettle();
      verify(() => harness.router.push<void>('/settings/instances')).called(1);
    });
  });

  group('translateEngineDescriptor', () {
    test('says modestly what each engine is good for', () {
      final l10n = lookupAppLocalizations(const Locale('en'));
      String? about(TranslationEngine engine) =>
          translateEngineDescriptor(l10n, engine);
      TranslationEngine mozhi(String name) =>
          TranslationEngine.mozhi(name, name);
      expect(about(google), 'Covers the most languages');
      expect(about(deepl), 'Good for European languages');
      expect(about(_deeplApi), 'Good for European languages');
      expect(
        about(mozhi('duckduckgo')),
        'Microsoft Translator, via DuckDuckGo',
      );
      expect(about(mozhi('bing')), 'Microsoft Translator, via DuckDuckGo');
      expect(about(mozhi('mymemory')), contains('short phrases'));
      expect(about(mozhi('reverso')), contains('idioms'));
      expect(about(mozhi('yandex')), contains('Russian'));
      expect(about(mozhi('libre')), 'Open-source machine translation');
      expect(about(_libre), 'Open-source machine translation');
      expect(about(mozhi('unknown')), isNull);
      expect(about(_offline), contains('this device'));
      expect(about(claude), contains('tone'));
      const gemma = TranslationEngine(
        id: 'ai:gemma',
        kind: EngineKind.ai,
        name: 'Gemma',
        providerId: 'gemma',
        promptProfile: PromptProfile.translateGemma,
      );
      expect(about(gemma), contains('no options'));
      const llm = TranslationEngine(
        id: 'mt:llm',
        kind: EngineKind.mt,
        name: 'LLM',
        mtService: MtService.llm,
      );
      expect(about(llm), isNull);
    });
  });

  group('isOnDeviceEngine', () {
    test('is true for offline engines only', () {
      expect(isOnDeviceEngine(_offline), isTrue);
      expect(isOnDeviceEngine(deepl), isFalse);
      expect(isOnDeviceEngine(claude), isFalse);
      expect(isOnDeviceEngine(ollama), isFalse);
      expect(isOnDeviceEngine(_deeplApi), isFalse);
      expect(isOnDeviceEngine(_libre), isFalse);
    });

    test('recognises offline engine ids', () {
      const other = TranslationEngine(
        id: 'offline:other',
        kind: EngineKind.mozhi,
        name: 'Other',
      );
      expect(isOnDeviceEngine(other), isTrue);
    });
  });

  group('EngineIcon', () {
    Future<IconData?> iconOf(
      WidgetTester tester,
      TranslationEngine engine,
    ) async {
      await tester.pumpApp(EngineIcon(engine: engine, size: 20));
      final icon = tester.widget<Icon>(find.byType(Icon));
      expect(icon.size, 20);
      return icon.icon;
    }

    testWidgets('shows the offline icon for offline engines', (tester) async {
      expect(await iconOf(tester, _offline), OfflineEngineBadge.icon);
    });

    testWidgets('tells local and cloud AI apart', (tester) async {
      expect(await iconOf(tester, ollama), Icons.memory);
      expect(await iconOf(tester, claude), Icons.auto_awesome_outlined);
    });

    testWidgets('shows the translate icon for Mozhi engines and services', (
      tester,
    ) async {
      expect(await iconOf(tester, deepl), Icons.translate);
      expect(await iconOf(tester, _deeplApi), Icons.translate);
      expect(await iconOf(tester, _libre), Icons.translate);
    });
  });

  group('PrivacyBadge', () {
    Future<String> labelOf(
      WidgetTester tester,
      TranslationEngine engine,
    ) async {
      await tester.pumpApp(PrivacyBadge(engine: engine));
      return tester.widget<Text>(find.byType(Text)).data!;
    }

    testWidgets('says where the text goes for each kind', (tester) async {
      expect(await labelOf(tester, deepl), 'Public server');
      expect(await labelOf(tester, claude), 'Cloud');
      expect(await labelOf(tester, ollama), 'Self-hosted');
      expect(await labelOf(tester, _deeplApi), 'Cloud');
      expect(await labelOf(tester, _libre), 'Self-hosted');
      expect(await labelOf(tester, _offline), 'On device');
    });

    testWidgets('names a self-hosted Mozhi instance by its destination', (
      tester,
    ) async {
      await tester.pumpApp(
        const PrivacyBadge(
          engine: deepl,
          destination: SelfHostedDestination('192.168.1.10'),
        ),
      );
      expect(find.text('Self-hosted'), findsOneWidget);
    });

    testWidgets('asks the repository for the destination', (tester) async {
      final repository = _MockRepository();
      when(() => repository.destinationOf('mozhi:deepl'))
          .thenReturn(const SelfHostedDestination('mozhi.lan'));
      await tester.pumpApp(
        RepositoryProvider<TranslationRepository>.value(
          value: repository,
          child: const PrivacyBadge(engine: deepl),
        ),
      );
      expect(find.text('Self-hosted'), findsOneWidget);
    });
  });
}
