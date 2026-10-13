import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:material_ui/material_ui.dart';
import 'package:mocktail/mocktail.dart';
import 'package:mozhi/settings/models/app_settings.dart';
import 'package:mozhi/settings/view/settings_page.dart';
import 'package:mozhi/settings/view/widgets/history_data_actions.dart';
import 'package:translation_repository/translation_repository.dart';

import 'helpers.dart';

const _claude = AiProviderConfig(
  id: 'p1',
  name: 'Claude',
  provider: LlmProvider.anthropic,
  baseUrl: 'https://api.anthropic.com/v1',
  model: 'claude-opus-5-5',
);

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
      Size size = const Size(800, 3000),
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

      testWidgets('show transliteration', (tester) async {
        await pump(tester);
        await tester.tap(find.text('Show transliteration'));
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
        verify(() => settings.setAssistEngine(null)).called(1);
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
        tester.setScreenSize(const Size(800, 3000));
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

      testWidgets('pure black toggles in dark/system mode', (tester) async {
        await pump(tester);
        await tester.tap(find.text('Pure black'));
        verify(() => settings.setPureBlack(enabled: true)).called(1);
      });

      testWidgets('pure black is disabled in light mode', (tester) async {
        await pump(
          tester,
          state: const AppSettings(themeMode: ThemeMode.light),
        );
        await tester.tap(find.text('Pure black'));
        verifyNever(
          () => settings.setPureBlack(enabled: any(named: 'enabled')),
        );
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
        when(() => history.importJson(any())).thenAnswer((_) async {});
        await pump(tester);
        await tester.tap(find.text('Import history'));
        await tester.pumpAndSettle();
        await tester.enterText(find.byType(TextField), '[]');
        await tester.tap(find.text('Import'));
        await tester.pumpAndSettle();
        verify(() => history.importJson('[]')).called(1);
        expect(find.byType(AlertDialog), findsNothing);
        expect(find.text('History imported'), findsOneWidget);
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
        );
        expect(tester.takeException(), isNull);
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
