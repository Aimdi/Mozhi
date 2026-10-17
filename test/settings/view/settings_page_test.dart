import 'dart:async';

import 'package:flutter/foundation.dart';
import 'package:flutter/services.dart';
import 'package:flutter_bloc/flutter_bloc.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:material_ui/material_ui.dart';
import 'package:mocktail/mocktail.dart';
import 'package:mozhi/app/theme.dart';
import 'package:mozhi/core/on_device_ml.dart';
import 'package:mozhi/core/widgets/x_ui.dart';
import 'package:mozhi/history/cubit/history_cubit.dart';
import 'package:mozhi/history/data/history_repository.dart';
import 'package:mozhi/history/models/history_entry.dart';
import 'package:mozhi/platform/clipboard_service.dart';
import 'package:mozhi/platform/privacy_channel.dart';
import 'package:mozhi/settings/models/app_settings.dart';
import 'package:mozhi/settings/view/settings_page.dart';
import 'package:mozhi/settings/view/widgets/history_data_actions.dart';
import 'package:mozhi/settings/view/widgets/settings_section.dart';
import 'package:mozhi/settings/view/widgets/speech_settings_section.dart';
import 'package:mozhi/speech/speech_service.dart';
import 'package:translation_repository/translation_repository.dart';

import 'helpers.dart';

const _claude = AiProviderConfig(
  id: 'p1',
  name: 'Claude',
  provider: LlmProvider.anthropic,
  baseUrl: 'https://api.anthropic.com/v1',
  model: 'claude-opus-5-5',
);

class _MockSpeechService extends Mock implements SpeechService;

const _local = AiProviderConfig(
  id: 'p2',
  name: 'Local Qwen',
  provider: LlmProvider.ollama,
  baseUrl: 'http://localhost:11434',
  model: 'qwen3',
  enabled: false,
);

void main() {
  setUpAll(registerFallbacks);

  group('SettingsPage', () {
    late MockSettingsCubit settings;
    late MockHistoryCubit history;
    late MockGoRouter router;

    setUp(() {
      settings = createSettingsCubit(
        const AppSettings(
          instances: [
            MozhiInstance(url: 'https://mozhi.example.com'),
            MozhiInstance(url: 'https://other.example.org'),
          ],
          providers: [_claude, _local],
        ),
      );
      history = createHistoryCubit();
      router = createRouter();
    });

    Future<void> pump(
      WidgetTester tester, {
      AppSettings? state,
      Size size = const Size(800, 5000),
      double textScale = 1,
    }) async {
      if (state != null) when(() => settings.state).thenReturn(state);
      tester.setScreenSize(size);
      await tester.pumpView(
        const SettingsPage(),
        settings: settings,
        history: history,
        router: router,
        textScale: textScale,
      );
    }

    testWidgets('renders all sections', (tester) async {
      await pump(tester);
      expect(find.text('Settings'), findsOneWidget);
      expect(find.text('Translation services'), findsOneWidget);
      expect(find.text('Translation'), findsOneWidget);
      expect(find.text('Appearance'), findsOneWidget);
      expect(find.text('Data'), findsOneWidget);
      expect(find.text('About Mozhi'), findsOneWidget);
    });

    testWidgets('summarises instances and providers', (tester) async {
      await pump(tester);
      expect(find.text('mozhi.example.com · 2 instances'), findsOneWidget);
      expect(find.text('1 of 2 enabled'), findsOneWidget);
    });

    testWidgets('shows hints when nothing is configured', (tester) async {
      await pump(tester, state: const AppSettings(instances: []));
      expect(
        find.text('No instances. Add one to use Mozhi engines.'),
        findsOneWidget,
      );
      expect(
        find.text('Use your own API key or a local model'),
        findsOneWidget,
      );
      expect(
        find.text(
          'Add an AI provider for alternatives, insights and explanations',
        ),
        findsOneWidget,
      );
    });

    testWidgets('navigates to sub pages', (tester) async {
      await pump(tester);
      await tester.tap(find.text('Mozhi instances'));
      verify(
        () => router.push<Object?>(
          '/settings/instances',
          extra: any(named: 'extra'),
        ),
      ).called(1);
      await tester.tap(find.text('AI providers'));
      verify(
        () => router.push<Object?>(
          '/settings/providers',
          extra: any(named: 'extra'),
        ),
      ).called(1);
      await tester.tap(find.text('About Mozhi'));
      verify(
        () =>
            router.push<Object?>('/settings/about', extra: any(named: 'extra')),
      ).called(1);
    });

    group('round-2 pages', () {
      Future<void> expectPush(
        WidgetTester tester,
        String title,
        String location,
      ) async {
        await tester.ensureVisible(find.text(title));
        await tester.tap(find.text(title));
        verify(() => router.push<Object?>(location, extra: any(named: 'extra')))
            .called(1);
      }

      testWidgets('opens offline languages, usage, presets and glossaries', (
        tester,
      ) async {
        await pump(tester);
        await expectPush(tester, 'Offline languages', '/settings/offline');
        await expectPush(tester, 'Usage & costs', '/settings/usage');
        await expectPush(tester, 'Presets', '/settings/presets');
        await expectPush(tester, 'Glossaries', '/settings/glossaries');
        await expectPush(tester, 'Run setup again', '/onboarding');
      });

      testWidgets('groups the entries into sections', (tester) async {
        await pump(tester);
        Finder inSection(String section, String title) => find.descendant(
          of: find.ancestor(
            of: find.text(section),
            matching: find.byType(SettingsSection),
          ),
          matching: find.text(title),
        );
        expect(
          inSection('Translation services', 'Offline languages'),
          findsOne,
        );
        expect(inSection('Translation services', 'Usage & costs'), findsOne);
        expect(inSection('Translation tools', 'Presets'), findsOne);
        expect(inSection('Translation tools', 'Glossaries'), findsOne);
        expect(inSection('Translation tools', 'Quality modes'), findsOne);
        expect(inSection('Privacy', 'Save history'), findsOne);
        expect(inSection('Privacy', 'Incognito'), findsOne);
        expect(inSection('Privacy', 'Delete all local data'), findsOne);
        expect(inSection('Data', 'Export history'), findsOne);
        expect(inSection('About', 'Run setup again'), findsOne);
      });

      for (final platform in [TargetPlatform.android, TargetPlatform.iOS]) {
        testWidgets('shows offline languages on ${platform.name}', (
          tester,
        ) async {
          debugDefaultTargetPlatformOverride = platform;
          await pump(tester);
          expect(find.text('Offline languages'), findsOneWidget);
          expect(SettingsView.offlineSupported, isTrue);
          debugDefaultTargetPlatformOverride = null;
        });
      }

      testWidgets('explains offline languages missing from the build', (
        tester,
      ) async {
        debugDefaultTargetPlatformOverride = TargetPlatform.android;
        debugOfflineEngineIncludedOverride = false;
        await pump(tester);
        expect(SettingsView.offlineSupported, isFalse);
        final tile = tester.widget<ListTile>(
          find.ancestor(
            of: find.text('Offline languages'),
            matching: find.byType(ListTile),
          ),
        );
        expect(tile.enabled, isFalse);
        expect(tile.onTap, isNull);
        expect(
          find.text(
            'Not included in this build: it needs Google ML Kit, which is '
            'not free software',
          ),
          findsOneWidget,
        );
        debugOfflineEngineIncludedOverride = null;
        debugDefaultTargetPlatformOverride = null;
      });

      for (final platform in [
        TargetPlatform.linux,
        TargetPlatform.macOS,
        TargetPlatform.windows,
      ]) {
        testWidgets('hides offline languages on ${platform.name}', (
          tester,
        ) async {
          debugDefaultTargetPlatformOverride = platform;
          await pump(tester);
          expect(find.text('Offline languages'), findsNothing);
          expect(find.text('Usage & costs'), findsOneWidget);
          expect(SettingsView.offlineSupported, isFalse);
          debugDefaultTargetPlatformOverride = null;
        });
      }
    });

    group('translation toggles', () {
      testWidgets('instant translate', (tester) async {
        await pump(tester);
        await tester.tap(find.text('Instant translate'));
        verify(() => settings.setInstantTranslate(enabled: false)).called(1);
      });

      testWidgets('instant translate with AI', (tester) async {
        await pump(tester);
        expect(find.textContaining('Uses more tokens'), findsOneWidget);
        await tester.tap(find.text('Instant translate with AI'));
        verify(() => settings.setInstantTranslateAi(enabled: true)).called(1);
      });

      testWidgets('save history', (tester) async {
        await pump(tester);
        await tester.tap(find.text('Save history'));
        verify(() => settings.setSaveHistory(enabled: false)).called(1);
      });

      testWidgets('show romanization', (tester) async {
        await pump(tester);
        expect(
          find.text(
            'Latin-script text under non-Latin text, when no cloud AI '
            'request is needed',
          ),
          findsOneWidget,
        );
        await tester.tap(find.text('Show romanization'));
        verify(() => settings.setShowTransliteration(enabled: false)).called(1);
      });
    });

    group('AI assistant picker', () {
      testWidgets('selects an enabled provider', (tester) async {
        await pump(tester);
        expect(find.text('Automatic'), findsOneWidget);
        await tester.tap(find.text('AI assistant for insights'));
        await tester.pumpAndSettle();
        expect(find.byType(AlertDialog), findsOneWidget);
        // Disabled providers are not offered.
        expect(find.text('Local Qwen'), findsNothing);
        await tester.tap(find.text('Claude'));
        await tester.pumpAndSettle();
        // Choosing only moves the selection; Save confirms it.
        expect(find.byType(AlertDialog), findsOneWidget);
        verifyNever(() => settings.setAssistEngine(any()));
        await tester.tap(find.text('Save'));
        await tester.pumpAndSettle();
        expect(find.byType(AlertDialog), findsNothing);
        verify(() => settings.setAssistEngine('ai:p1')).called(1);
      });

      testWidgets('selects automatic', (tester) async {
        await pump(
          tester,
          state: const AppSettings(
            providers: [_claude],
            assistEngineId: 'ai:p1',
          ),
        );
        expect(find.text('Claude'), findsOneWidget);
        await tester.tap(find.text('AI assistant for insights'));
        await tester.pumpAndSettle();
        await tester.tap(find.text('Automatic'));
        await tester.pumpAndSettle();
        await tester.tap(find.text('Save'));
        await tester.pumpAndSettle();
        verify(() => settings.setAssistEngine(null)).called(1);
      });

      testWidgets('arrow keys move the choice without closing the dialog', (
        tester,
      ) async {
        await pump(tester);
        await tester.tap(find.text('AI assistant for insights'));
        await tester.pumpAndSettle();
        await tester.sendKeyEvent(LogicalKeyboardKey.tab);
        await tester.pump();
        await tester.sendKeyEvent(LogicalKeyboardKey.arrowDown);
        await tester.pumpAndSettle();
        expect(find.byType(AlertDialog), findsOneWidget);
        verifyNever(() => settings.setAssistEngine(any()));

        await tester.tap(find.text('Save'));
        await tester.pumpAndSettle();
        expect(find.byType(AlertDialog), findsNothing);
        verify(() => settings.setAssistEngine('ai:p1')).called(1);
      });

      testWidgets('cancel keeps the selection', (tester) async {
        await pump(tester);
        await tester.tap(find.text('AI assistant for insights'));
        await tester.pumpAndSettle();
        await tester.tap(find.text('Cancel'));
        await tester.pumpAndSettle();
        verifyNever(() => settings.setAssistEngine(any()));
      });

      testWidgets('opens providers when none exist', (tester) async {
        await pump(tester, state: const AppSettings());
        await tester.tap(find.text('AI assistant for insights'));
        verify(
          () => router.push<Object?>(
            '/settings/providers',
            extra: any(named: 'extra'),
          ),
        ).called(1);
      });
    });

    group('appearance', () {
      testWidgets('changes theme mode', (tester) async {
        await pump(tester);
        await tester.tap(find.text('Dark'));
        verify(() => settings.setThemeMode(ThemeMode.dark)).called(1);
      });

      testWidgets('toggles dynamic color', (tester) async {
        await pump(tester);
        await tester.tap(find.text('Dynamic color'));
        verify(() => settings.setDynamicColor(enabled: false)).called(1);
      });

      testWidgets('hides accent colors with dynamic color', (tester) async {
        await pump(tester);
        expect(find.text('Accent color'), findsNothing);
      });

      testWidgets('picks an accent color without dynamic color', (
        tester,
      ) async {
        await pump(tester, state: const AppSettings(dynamicColor: false));
        expect(find.text('Accent color'), findsOneWidget);
        await tester.tap(find.bySemanticsLabel('Teal'));
        verify(() => settings.setSeedColor(0xFF00897B)).called(1);
      });

      testWidgets('accent colors always shown on iOS', (tester) async {
        when(() => settings.state).thenReturn(const AppSettings());
        tester.setScreenSize(const Size(800, 5000));
        await tester.pumpView(
          const SettingsPage(),
          settings: settings,
          history: history,
          router: router,
          theme: ThemeData(platform: TargetPlatform.iOS),
        );
        expect(find.text('Dynamic color'), findsNothing);
        expect(find.text('Accent color'), findsOneWidget);
      });

      testWidgets('marks the selected theme with a check', (tester) async {
        await pump(tester);
        expect(
          find.descendant(
            of: find.byType(SegmentedButton<ThemeMode>),
            matching: find.byIcon(Icons.check),
          ),
          findsOneWidget,
        );
        expect(find.bySemanticsLabel('Theme'), findsOneWidget);
      });

      testWidgets('uses radio rows for the theme with large text', (
        tester,
      ) async {
        await pump(tester, textScale: 2, size: const Size(800, 10000));
        expect(find.byType(SegmentedButton<ThemeMode>), findsNothing);
        expect(find.byType(RadioListTile<ThemeMode>), findsNWidgets(3));
        await tester.ensureVisible(find.text('Dark'));
        await tester.tap(find.text('Dark'));
        verify(() => settings.setThemeMode(ThemeMode.dark)).called(1);
      });

      testWidgets('accent swatches keep their tap action for screen readers', (
        tester,
      ) async {
        final handle = tester.ensureSemantics();
        await pump(tester, state: const AppSettings(dynamicColor: false));
        final node = tester.getSemantics(find.bySemanticsLabel('Teal'));
        expect(
          node,
          isSemantics(
            label: 'Teal',
            isButton: true,
            hasTapAction: true,
            isInMutuallyExclusiveGroup: true,
            hasSelectedState: true,
            isSelected: false,
          ),
        );
        expect(
          tester.getSemantics(find.bySemanticsLabel('Blue')),
          isSemantics(isSelected: true),
        );
        expect(node.id, isNonZero);
        tester.semantics.tap(find.semantics.byLabel('Teal'));
        verify(() => settings.setSeedColor(0xFF00897B)).called(1);
        handle.dispose();
      });

      testWidgets('swatches do not animate with reduced motion', (
        tester,
      ) async {
        when(() => settings.state)
            .thenReturn(const AppSettings(dynamicColor: false));
        tester.setScreenSize(const Size(800, 3000));
        await tester.pumpView(
          Builder(
            builder: (context) => MediaQuery(
              data: MediaQuery.of(context).copyWith(disableAnimations: true),
              child: const SettingsPage(),
            ),
          ),
          settings: settings,
          history: history,
          router: router,
        );
        final containers = tester.widgetList<AnimatedContainer>(
          find.byType(AnimatedContainer),
        );
        expect(containers, isNotEmpty);
        expect(containers.map((c) => c.duration), everyElement(Duration.zero));
      });

      testWidgets('offers X accents with blue first', (tester) async {
        await pump(tester, state: const AppSettings(dynamicColor: false));
        for (final name in [
          'Blue',
          'Yellow',
          'Pink',
          'Purple',
          'Orange',
          'Green',
        ]) {
          expect(find.bySemanticsLabel(name), findsOneWidget, reason: name);
        }
        expect(
          tester.getTopLeft(find.bySemanticsLabel('Blue')).dx,
          lessThan(tester.getTopLeft(find.bySemanticsLabel('Yellow')).dx),
        );
      });

      testWidgets('picks Lights out or Dim for the dark theme', (tester) async {
        final handle = tester.ensureSemantics();
        await pump(tester);
        expect(find.text('Dark theme'), findsOneWidget);
        expect(find.bySemanticsLabel('Dark theme'), findsOneWidget);
        expect(
          tester
              .widget<RadioGroup<bool>>(find.byType(RadioGroup<bool>))
              .groupValue,
          isFalse,
        );
        await tester.tap(find.text('Lights out'));
        verify(() => settings.setPureBlack(enabled: true)).called(1);
        // Picking the current look again is a no-op.
        await tester.tap(find.text('Dim'));
        verifyNever(
          () => settings.setPureBlack(enabled: any(named: 'enabled')),
        );
        handle.dispose();
      });

      testWidgets('switches back to Dim', (tester) async {
        await pump(tester, state: const AppSettings(pureBlack: true));
        await tester.tap(find.text('Dim'));
        verify(() => settings.setPureBlack(enabled: false)).called(1);
      });

      testWidgets('the dark look is disabled in light mode', (tester) async {
        await pump(
          tester,
          state: const AppSettings(themeMode: ThemeMode.light),
        );
        final tiles = tester.widgetList<RadioListTile<bool>>(
          find.byType(RadioListTile<bool>),
        );
        expect(tiles.map((t) => t.enabled), everyElement(isFalse));
        await tester.tap(find.text('Lights out'), warnIfMissed: false);
        verifyNever(
          () => settings.setPureBlack(enabled: any(named: 'enabled')),
        );
      });

      testWidgets('renders in the app theme (light and Lights out)', (
        tester,
      ) async {
        for (final theme in [
          buildAppTheme(
            appColorScheme(
              brightness: Brightness.light,
              seedColor: const Color(0xFF1D9BF0),
            ),
          ),
          buildAppTheme(
            appColorScheme(
              brightness: Brightness.dark,
              seedColor: const Color(0xFF1D9BF0),
              pureBlack: true,
            ),
          ),
        ]) {
          when(() => settings.state).thenReturn(const AppSettings());
          tester.setScreenSize(const Size(800, 3000));
          await tester.pumpView(
            const SettingsPage(),
            settings: settings,
            history: history,
            router: router,
            theme: theme,
          );
          await tester.pumpAndSettle();
          // Plain rows: no tinted icon squares, bold section headings.
          final heading = tester.widget<Text>(find.text('Appearance'));
          expect(heading.style?.fontWeight, FontWeight.w800);
          expect(find.byType(Card), findsNothing);
          expect(
            tester.widget<Icon>(find.byIcon(Icons.dns_outlined)).color,
            theme.extension<AppPalette>()!.secondaryText,
          );
          expect(find.byType(Hairline), findsWidgets);
        }
      });
    });

    group('data', () {
      setUp(() {
        when(history.exportJson).thenAnswer((_) async => '[{"id":"1"}]');
      });

      testWidgets('exports history to the clipboard', (tester) async {
        String? copied;
        tester.binding.defaultBinaryMessenger.setMockMethodCallHandler(
          SystemChannels.platform,
          (call) async {
            if (call.method == 'Clipboard.setData') {
              copied = (call.arguments as Map)['text'] as String?;
            }
            return null;
          },
        );
        addTearDown(
          () => tester.binding.defaultBinaryMessenger.setMockMethodCallHandler(
            SystemChannels.platform,
            null,
          ),
        );
        await pump(tester);
        await tester.tap(find.text('Export history'));
        await tester.pumpAndSettle();
        await tester.tap(find.text('Copy JSON to clipboard'));
        await tester.pumpAndSettle();
        verify(history.exportJson).called(1);
        expect(copied, '[{"id":"1"}]');
        expect(find.text('History copied as JSON'), findsOneWidget);
      });

      testWidgets('warns that the export is not encrypted', (tester) async {
        await pump(tester);
        await tester.tap(find.text('Export history'));
        await tester.pumpAndSettle();
        expect(find.byType(ExportUnencryptedWarning), findsOneWidget);
        expect(
          find.text(
            "The exported JSON isn't encrypted: anyone who can open it can "
            'read your history. Keep it somewhere safe.',
          ),
          findsOneWidget,
        );
      });

      testWidgets('marks the copy sensitive and leaves the confirmation to '
          'Android 13+', (tester) async {
        final previous = ClipboardService.instance;
        addTearDown(() => ClipboardService.instance = previous);
        final copied = <String>[];
        tester.binding.defaultBinaryMessenger.setMockMethodCallHandler(
          privacyChannel(),
          (call) async {
            copied.add(call.arguments as String);
            return true;
          },
        );
        addTearDown(
          () => tester.binding.defaultBinaryMessenger.setMockMethodCallHandler(
            privacyChannel(),
            null,
          ),
        );
        ClipboardService.instance = ClipboardService(isAndroid: true);
        await pump(tester);
        await tester.tap(find.text('Export history'));
        await tester.pumpAndSettle();
        await tester.tap(find.text('Copy JSON to clipboard'));
        await tester.pumpAndSettle();

        expect(copied, ['[{"id":"1"}]']);
        expect(find.text('History copied as JSON'), findsNothing);
      });

      testWidgets('the import field keeps keyboards from learning while '
          'incognito', (tester) async {
        await pump(tester, state: const AppSettings(incognito: true));
        await tester.tap(find.text('Import history'));
        await tester.pumpAndSettle();
        final field = tester.widget<TextField>(
          find.descendant(
            of: find.byType(ImportHistoryDialog),
            matching: find.byType(TextField),
          ),
        );
        expect(field.enableIMEPersonalizedLearning, isFalse);
      });

      testWidgets('shares exported history', (tester) async {
        final shared = <String>[];
        final original = HistoryShare.share;
        HistoryShare.share = (json) async => shared.add(json);
        addTearDown(() => HistoryShare.share = original);
        await pump(tester);
        await tester.tap(find.text('Export history'));
        await tester.pumpAndSettle();
        await tester.tap(find.text('Share as file'));
        await tester.pumpAndSettle();
        expect(shared, ['[{"id":"1"}]']);
      });

      testWidgets('reports export failures', (tester) async {
        when(history.exportJson).thenThrow(Exception('disk'));
        await pump(tester);
        await tester.tap(find.text('Export history'));
        await tester.pumpAndSettle();
        await tester.tap(find.text('Copy JSON to clipboard'));
        await tester.pumpAndSettle();
        expect(find.text("Couldn't export history"), findsOneWidget);
      });

      testWidgets('imports pasted JSON', (tester) async {
        when(() => history.importJson(any())).thenAnswer(
          (_) async => const HistoryImport(entries: [], added: 0, expired: 0),
        );
        await pump(tester);
        await tester.tap(find.text('Import history'));
        await tester.pumpAndSettle();
        // Labelled, not only hinted, so it stays named once filled.
        expect(
          tester
              .widget<TextField>(find.byType(TextField))
              .decoration
              ?.labelText,
          'History JSON',
        );
        await tester.enterText(find.byType(TextField), '[]');
        await tester.tap(find.text('Import'));
        await tester.pumpAndSettle();
        verify(() => history.importJson('[]')).called(1);
        expect(find.byType(AlertDialog), findsNothing);
        expect(find.text('History imported'), findsOneWidget);
      });

      testWidgets('says how many old translations were skipped', (
        tester,
      ) async {
        when(() => history.importJson(any())).thenAnswer(
          (_) async => const HistoryImport(entries: [], added: 1, expired: 340),
        );
        await pump(tester);
        await tester.tap(find.text('Import history'));
        await tester.pumpAndSettle();
        await tester.enterText(find.byType(TextField), '[]');
        await tester.tap(find.text('Import'));
        await tester.pumpAndSettle();

        expect(find.byType(AlertDialog), findsNothing);
        expect(
          find.text(
            'History imported. 340 translations were skipped because they '
            'are older than your auto-delete period.',
          ),
          findsOneWidget,
        );
        expect(find.text('History imported'), findsNothing);
      });

      testWidgets('cancelling the import shows nothing', (tester) async {
        await pump(tester);
        await tester.tap(find.text('Import history'));
        await tester.pumpAndSettle();
        await tester.tap(find.text('Cancel'));
        await tester.pumpAndSettle();

        expect(find.byType(AlertDialog), findsNothing);
        expect(find.byType(SnackBar), findsNothing);
        verifyNever(() => history.importJson(any()));
      });

      testWidgets('pastes from the clipboard', (tester) async {
        tester.binding.defaultBinaryMessenger.setMockMethodCallHandler(
          SystemChannels.platform,
          (call) async => call.method == 'Clipboard.getData'
              ? <String, dynamic>{'text': '[{"id":"2"}]'}
              : null,
        );
        addTearDown(
          () => tester.binding.defaultBinaryMessenger.setMockMethodCallHandler(
            SystemChannels.platform,
            null,
          ),
        );
        await pump(tester);
        await tester.tap(find.text('Import history'));
        await tester.pumpAndSettle();
        await tester.tap(find.text('Paste from clipboard'));
        await tester.pumpAndSettle();
        expect(find.text('[{"id":"2"}]'), findsOneWidget);
      });

      testWidgets('shows an error for invalid JSON', (tester) async {
        when(() => history.importJson(any()))
            .thenThrow(const FormatException('bad'));
        await pump(tester);
        await tester.tap(find.text('Import history'));
        await tester.pumpAndSettle();
        await tester.tap(find.text('Import'));
        await tester.pumpAndSettle();
        // Empty input is rejected without calling the cubit.
        verifyNever(() => history.importJson(any()));
        expect(find.text("This isn't valid Mozhi history JSON."), findsOne);

        await tester.enterText(find.byType(TextField), 'nope');
        await tester.tap(find.text('Import'));
        await tester.pumpAndSettle();
        verify(() => history.importJson('nope')).called(1);
        expect(find.text("This isn't valid Mozhi history JSON."), findsOne);
        expect(find.byType(AlertDialog), findsOneWidget);
      });

      testWidgets('clears history keeping favorites by default', (
        tester,
      ) async {
        await pump(tester);
        await tester.tap(find.text('Clear history'));
        await tester.pumpAndSettle();
        expect(find.text('Clear history?'), findsOneWidget);
        await tester.tap(find.text('Clear'));
        await tester.pumpAndSettle();
        verify(() => history.clear(keepFavorites: true)).called(1);
        expect(find.text('History cleared'), findsOneWidget);
      });

      testWidgets('clears everything when unchecked', (tester) async {
        await pump(tester);
        await tester.tap(find.text('Clear history'));
        await tester.pumpAndSettle();
        await tester.tap(find.text('Keep favorites'));
        await tester.pump();
        await tester.tap(find.text('Clear'));
        await tester.pumpAndSettle();
        verify(() => history.clear()).called(1);
      });

      testWidgets('cancel does not clear', (tester) async {
        await pump(tester);
        await tester.tap(find.text('Clear history'));
        await tester.pumpAndSettle();
        await tester.tap(find.text('Cancel'));
        await tester.pumpAndSettle();
        verifyNever(
          () => history.clear(keepFavorites: any(named: 'keepFavorites')),
        );
      });
    });

    group('read aloud', () {
      late _MockSpeechService speech;

      setUp(() {
        speech = _MockSpeechService();
        when(() => speech.speaking).thenAnswer((_) => const Stream.empty());
        when(() => speech.current).thenReturn(null);
        when(() => speech.deviceVoiceSupported).thenReturn(true);
        when(() => speech.preferDeviceVoice).thenReturn(false);
        when(speech.loadPreferDeviceVoice).thenAnswer((_) async => false);
        when(speech.loadSettings)
            .thenAnswer((_) async => const SpeechSettings());
        when(speech.stop).thenAnswer((_) async {});
      });

      testWidgets('is hidden without a speech service', (tester) async {
        await pump(tester);

        expect(find.byType(SpeechSettingsSection), findsNothing);
      });

      testWidgets('offers voices for the languages in use', (tester) async {
        when(() => settings.state).thenReturn(
          const AppSettings(
            source: Language(code: 'de', name: 'German'),
            target: Language(code: 'fr', name: 'French'),
            recentLanguages: [
              Language(code: 'fr', name: 'French'),
              Language(code: 'es', name: 'Spanish'),
            ],
          ),
        );
        tester.setScreenSize(const Size(800, 4000));
        await tester.pumpView(
          RepositoryProvider<SpeechService>.value(
            value: speech,
            child: const SettingsPage(),
          ),
          settings: settings,
          history: history,
          router: router,
        );
        await tester.pump();

        expect(find.text('Read aloud'), findsOneWidget);
        expect(find.text('Speech rate'), findsOneWidget);
        expect(
          [
            for (final text in tester.widgetList<Text>(
              find.textContaining(RegExp(r'^\w+ voice$')),
            ))
              text.data,
          ],
          ['French voice', 'German voice', 'Spanish voice'],
        );
        // In the first column, after the translation settings.
        expect(
          tester.getTopLeft(find.text('Read aloud')).dy,
          greaterThan(tester.getTopLeft(find.text('Translation')).dy),
        );
        expect(
          tester.getTopLeft(find.text('Read aloud')).dy,
          lessThan(tester.getTopLeft(find.text('Appearance')).dy),
        );
      });

      testWidgets('leaves no empty semantics node over the settings list', (
        tester,
      ) async {
        final handle = tester.ensureSemantics();
        const size = Size(412, 915);
        tester.setScreenSize(size);
        await tester.pumpView(
          RepositoryProvider<SpeechService>.value(
            value: speech,
            child: const SettingsPage(),
          ),
          settings: settings,
          history: history,
          router: router,
        );
        await tester.pump();
        // The list builds lazily: bring the rate slider in.
        await tester.scrollUntilVisible(
          find.byType(Slider),
          200,
          scrollable: find.byType(Scrollable).first,
        );
        expect(find.byType(Slider), findsOneWidget);

        // The rate slider's overlay used to add a screen-sized leaf without
        // a label or actions above the list (on the web it blocked clicks).
        final covering = find.semantics.byPredicate((node) {
          final data = node.getSemanticsData();
          return !node.isMergedIntoParent &&
              !node.hasChildren &&
              data.label.isEmpty &&
              data.actions == 0 &&
              node.rect.width >= size.width &&
              node.rect.height >= size.height / 2;
        });
        expect(covering, findsNothing);
        handle.dispose();
      });
    });

    group('quality modes', () {
      testWidgets('opens the quality modes page', (tester) async {
        await pump(tester);
        await tester.ensureVisible(find.text('Quality modes'));
        await tester.tap(find.text('Quality modes'));
        verify(
          () => router.push<Object?>(
            '/settings/quality',
            extra: any(named: 'extra'),
          ),
        ).called(1);
      });

      testWidgets('lives in the translation tools section', (tester) async {
        await pump(tester);
        expect(
          find.descendant(
            of: find.ancestor(
              of: find.text('Translation tools'),
              matching: find.byType(SettingsSection),
            ),
            matching: find.text('Quality modes'),
          ),
          findsOne,
        );
      });
    });

    group('history retention', () {
      Future<void> openPicker(WidgetTester tester) async {
        await tester.ensureVisible(find.text('Delete history automatically'));
        await tester.tap(find.text('Delete history automatically'));
        await tester.pumpAndSettle();
      }

      testWidgets('lives in the privacy section and shows the retention', (
        tester,
      ) async {
        await pump(
          tester,
          state: const AppSettings(historyRetention: HistoryRetention.week),
        );
        expect(
          find.descendant(
            of: find.ancestor(
              of: find.text('Privacy'),
              matching: find.byType(SettingsSection),
            ),
            matching: find.text('Delete history automatically'),
          ),
          findsOne,
        );
        expect(find.text('After 7 days'), findsOneWidget);
      });

      testWidgets('shows "Never" by default', (tester) async {
        await pump(tester);
        expect(find.text('Never'), findsOneWidget);
      });

      testWidgets('picks a retention', (tester) async {
        await pump(tester);
        await openPicker(tester);
        expect(find.byType(AlertDialog), findsOneWidget);
        expect(
          find.text(
            'Translations older than this are deleted from this device. '
            'Favorites are always kept.',
          ),
          findsOneWidget,
        );
        expect(find.text('After 1 day'), findsOneWidget);
        expect(find.text('After 7 days'), findsOneWidget);
        await tester.tap(find.text('After 30 days'));
        await tester.pumpAndSettle();
        // Choosing only moves the selection; Save confirms it.
        expect(find.byType(AlertDialog), findsOneWidget);
        verifyNever(() => settings.setHistoryRetention(any()));
        await tester.tap(find.text('Save'));
        await tester.pumpAndSettle();
        expect(find.byType(AlertDialog), findsNothing);
        verify(() => settings.setHistoryRetention(HistoryRetention.month))
            .called(1);
      });

      testWidgets('picking the current retention changes nothing', (
        tester,
      ) async {
        await pump(
          tester,
          state: const AppSettings(historyRetention: HistoryRetention.day),
        );
        await openPicker(tester);
        await tester.tap(find.text('After 1 day').last);
        await tester.pumpAndSettle();
        await tester.tap(find.text('Save'));
        await tester.pumpAndSettle();
        expect(find.byType(AlertDialog), findsNothing);
        verifyNever(() => settings.setHistoryRetention(any()));
      });

      testWidgets('arrow keys move the choice without closing the dialog', (
        tester,
      ) async {
        await pump(tester);
        await openPicker(tester);
        // Tab reaches the selected radio of the group.
        await tester.sendKeyEvent(LogicalKeyboardKey.tab);
        await tester.pump();
        await tester.sendKeyEvent(LogicalKeyboardKey.arrowDown);
        await tester.pumpAndSettle();
        expect(find.byType(AlertDialog), findsOneWidget);
        await tester.sendKeyEvent(LogicalKeyboardKey.arrowDown);
        await tester.pumpAndSettle();
        expect(find.byType(AlertDialog), findsOneWidget);
        verifyNever(() => settings.setHistoryRetention(any()));

        // Tab to Save past Cancel and confirm.
        await tester.sendKeyEvent(LogicalKeyboardKey.tab);
        await tester.sendKeyEvent(LogicalKeyboardKey.tab);
        await tester.pump();
        expect(
          Focus.of(tester.element(find.text('Save'))).hasPrimaryFocus,
          isTrue,
        );
        await tester.sendKeyEvent(LogicalKeyboardKey.enter);
        await tester.pumpAndSettle();
        expect(find.byType(AlertDialog), findsNothing);
        verify(() => settings.setHistoryRetention(HistoryRetention.week))
            .called(1);
      });

      testWidgets('cancel keeps the retention', (tester) async {
        await pump(tester);
        await openPicker(tester);
        await tester.tap(find.text('Cancel'));
        await tester.pumpAndSettle();
        verifyNever(() => settings.setHistoryRetention(any()));
      });

      group('when existing translations would be deleted', () {
        HistoryEntry entry(String id, Duration age, {bool favorite = false}) =>
            HistoryEntry(
              id: id,
              text: 'text $id',
              translation: 'translation $id',
              source: const Language(code: 'es', name: 'Spanish'),
              target: const Language(code: 'en', name: 'English'),
              engineId: 'mozhi:google',
              engineName: 'Google',
              createdAt: DateTime.now().subtract(age),
              isFavorite: favorite,
            );

        setUp(() {
          when(() => history.state).thenReturn(
            HistoryState(
              status: HistoryStatus.ready,
              entries: [
                entry('new', const Duration(hours: 1)),
                entry('old', const Duration(days: 3)),
                entry('older', const Duration(days: 40)),
                entry('starred', const Duration(days: 40), favorite: true),
              ],
            ),
          );
        });

        Future<void> pick(WidgetTester tester, String label) async {
          await openPicker(tester);
          await tester.tap(find.text(label));
          await tester.pumpAndSettle();
          await tester.tap(find.text('Save'));
          await tester.pumpAndSettle();
        }

        testWidgets('asks before deleting them', (tester) async {
          await pump(tester);
          await pick(tester, 'After 1 day');

          verifyNever(() => settings.setHistoryRetention(any()));
          expect(find.text('Delete older translations now?'), findsOneWidget);
          expect(
            find.text(
              '2 translations are older than 1 day and will be deleted from '
              'this device right away. Favorites are kept.',
            ),
            findsOneWidget,
          );

          await tester.tap(
            find.byKey(const Key('settings_history_retention_confirm')),
          );
          await tester.pumpAndSettle();
          expect(find.byType(AlertDialog), findsNothing);
          verify(() => settings.setHistoryRetention(HistoryRetention.day))
              .called(1);
        });

        testWidgets('counts only what the new retention deletes', (
          tester,
        ) async {
          await pump(tester);
          await pick(tester, 'After 30 days');

          expect(
            find.text(
              '1 translation is older than 30 days and will be deleted from '
              'this device right away. Favorites are kept.',
            ),
            findsOneWidget,
          );
        });

        testWidgets('keeps the retention when cancelled', (tester) async {
          await pump(tester);
          await pick(tester, 'After 7 days');
          expect(find.text('Delete older translations now?'), findsOneWidget);

          await tester.tap(find.text('Cancel'));
          await tester.pumpAndSettle();
          expect(find.byType(AlertDialog), findsNothing);
          verifyNever(() => settings.setHistoryRetention(any()));
        });

        testWidgets('keeps the retention when dismissed', (tester) async {
          await pump(tester);
          await pick(tester, 'After 7 days');

          await tester.tapAt(const Offset(4, 4));
          await tester.pumpAndSettle();
          expect(find.byType(AlertDialog), findsNothing);
          verifyNever(() => settings.setHistoryRetention(any()));
        });

        testWidgets('does not ask when nothing would be deleted', (
          tester,
        ) async {
          await pump(
            tester,
            state: const AppSettings(historyRetention: HistoryRetention.week),
          );
          await pick(tester, 'Never');

          expect(find.byType(AlertDialog), findsNothing);
          verify(() => settings.setHistoryRetention(HistoryRetention.forever))
              .called(1);
        });
      });
    });

    group('recent language pairs', () {
      const pairs = [
        LanguagePair(
          source: Language.auto,
          target: Language(code: 'en', name: 'English'),
        ),
        LanguagePair(
          source: Language(code: 'fr', name: 'French'),
          target: Language(code: 'de', name: 'German'),
        ),
      ];

      testWidgets('is disabled without recent pairs', (tester) async {
        await pump(tester);
        expect(find.text('No recent language pairs'), findsOneWidget);
        await tester.ensureVisible(find.text('Clear recent language pairs'));
        await tester.tap(find.text('Clear recent language pairs'));
        await tester.pump();
        verifyNever(settings.clearRecentPairs);
      });

      testWidgets('clears the recent pairs and can undo it', (tester) async {
        await pump(tester, state: const AppSettings(recentPairs: pairs));
        expect(find.text('2 recent language pairs'), findsOneWidget);
        await tester.ensureVisible(find.text('Clear recent language pairs'));
        await tester.tap(find.text('Clear recent language pairs'));
        await tester.pumpAndSettle();
        verify(settings.clearRecentPairs).called(1);
        expect(find.text('Recent language pairs cleared'), findsOneWidget);

        // Dismissable without a pointer and without undoing.
        final snackBar = tester.widget<SnackBar>(find.byType(SnackBar));
        expect(snackBar.showCloseIcon, isTrue);

        await tester.tap(find.text('Undo'));
        await tester.pump();
        final change =
            verify(() => settings.update(captureAny())).captured.single
                as AppSettings Function(AppSettings);
        expect(change(const AppSettings()).recentPairs, pairs);
        // Pairs recorded in the meantime stay first.
        const newer = LanguagePair(
          source: Language(code: 'es', name: 'Spanish'),
          target: Language(code: 'en', name: 'English'),
        );
        expect(
          change(AppSettings(recentPairs: [newer, pairs.first])).recentPairs,
          [newer, ...pairs],
        );
      });

      testWidgets('the cleared notice closes without undoing', (tester) async {
        await pump(tester, state: const AppSettings(recentPairs: pairs));
        await tester.ensureVisible(find.text('Clear recent language pairs'));
        await tester.tap(find.text('Clear recent language pairs'));
        await tester.pumpAndSettle();
        // It waits for the user instead of timing out.
        await tester.pump(const Duration(minutes: 1));
        expect(find.text('Recent language pairs cleared'), findsOneWidget);

        final close = find.descendant(
          of: find.byType(SnackBar),
          matching: find.byIcon(Icons.close),
        );
        expect(close, findsOneWidget);
        await tester.tap(close);
        await tester.pumpAndSettle();
        expect(find.text('Recent language pairs cleared'), findsNothing);
        verifyNever(() => settings.update(any()));
      });
    });

    group('layout', () {
      testWidgets('uses two columns on wide screens', (tester) async {
        await pump(tester, size: const Size(1400, 1600));
        final services = tester.getTopLeft(find.text('Translation services'));
        final appearance = tester.getTopLeft(find.text('Appearance'));
        expect(appearance.dx, greaterThan(services.dx));
      });

      testWidgets('fits 320dp with large text', (tester) async {
        await pump(
          tester,
          state: const AppSettings(dynamicColor: false, providers: [_claude]),
          size: const Size(320, 640),
          textScale: 2,
        );
        expect(tester.takeException(), isNull);
        await tester.dragUntilVisible(
          find.text('About Mozhi'),
          find.byType(ListView),
          const Offset(0, -300),
          maxIteration: 200,
        );
        expect(tester.takeException(), isNull);
      });

      testWidgets('keyboard focus finishes the left column first', (
        tester,
      ) async {
        await pump(tester, size: const Size(1400, 1600));
        final middle = tester.getCenter(find.byType(SettingsView)).dx;
        final columns = <int>[];
        FocusNode? first;
        for (var i = 0; i < 80; i++) {
          await tester.sendKeyEvent(LogicalKeyboardKey.tab);
          await tester.pump();
          final node = FocusManager.instance.primaryFocus!;
          // The page scrolls as focus moves: compare nodes, not rects.
          if (node == first) break;
          first ??= node;
          columns.add(node.rect.center.dx < middle ? 0 : 1);
        }
        expect(columns, contains(0));
        expect(columns, contains(1));
        final switchIndex = columns.indexOf(1);
        expect(
          columns.sublist(switchIndex),
          everyElement(1),
          reason: 'focus went back to the left column: $columns',
        );
      });

      testWidgets('renders in dark mode', (tester) async {
        when(() => settings.state).thenReturn(const AppSettings());
        tester.setScreenSize(const Size(800, 3000));
        await tester.pumpView(
          const SettingsPage(),
          settings: settings,
          history: history,
          router: router,
          theme: ThemeData(brightness: Brightness.dark),
        );
        expect(find.byType(SettingsView), findsOneWidget);
      });
    });
  });
}
