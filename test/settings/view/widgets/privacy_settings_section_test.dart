import 'package:flutter/foundation.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:material_ui/material_ui.dart';
import 'package:mocktail/mocktail.dart';
import 'package:mozhi/settings/models/app_settings.dart';
import 'package:mozhi/settings/view/widgets/privacy_settings_section.dart';
import 'package:mozhi/settings/view/widgets/settings_section.dart';
import 'package:translation_repository/translation_repository.dart';

import '../helpers.dart';

const _claude = AiProviderConfig(
  id: 'p1',
  name: 'Claude',
  provider: LlmProvider.anthropic,
  baseUrl: 'https://api.anthropic.com/v1',
  model: 'claude-opus-5-5',
);

void main() {
  setUpAll(() {
    registerFallbacks();
    registerFallbackValue(PrivacyMode.online);
  });

  group(PrivacySettingsSection, () {
    late MockSettingsCubit settings;
    late MockHistoryCubit history;
    late MockGoRouter router;

    setUp(() {
      settings = createSettingsCubit();
      history = createHistoryCubit();
      router = createRouter();
    });

    Future<void> pump(
      WidgetTester tester, [
      AppSettings state = const AppSettings(),
    ]) async {
      when(() => settings.state).thenReturn(state);
      tester.setScreenSize(const Size(800, 3000));
      await tester.pumpView(
        Scaffold(
          body: ListView(children: [PrivacySettingsSection(settings: state)]),
        ),
        settings: settings,
        history: history,
        router: router,
      );
    }

    testWidgets('is a settings section titled Privacy', (tester) async {
      await pump(tester);
      expect(
        find.ancestor(
          of: find.text('Privacy'),
          matching: find.byType(SettingsSection),
        ),
        findsOne,
      );
    });

    group('privacy mode', () {
      testWidgets('offers three modes with an explanation each', (
        tester,
      ) async {
        await pump(tester);
        expect(find.text('Privacy mode'), findsOneWidget);
        expect(find.text('Offline only'), findsOneWidget);
        expect(find.textContaining('Nothing you type leaves'), findsOneWidget);
        expect(find.text('Offline first'), findsOneWidget);
        expect(find.textContaining('Asks before text goes'), findsOneWidget);
        expect(find.text('Online'), findsOneWidget);
        expect(find.textContaining('without asking'), findsOneWidget);
        final selected = tester.widget<RadioGroup<PrivacyMode>>(
          find.byType(RadioGroup<PrivacyMode>),
        );
        expect(selected.groupValue, PrivacyMode.offlineFirst);
      });

      testWidgets('is a named group for screen readers', (tester) async {
        final handle = tester.ensureSemantics();
        await pump(tester);
        expect(find.bySemanticsLabel('Privacy mode'), findsOneWidget);
        handle.dispose();
      });

      testWidgets('changes the mode', (tester) async {
        await pump(tester);
        await tester.tap(find.text('Online'));
        verify(() => settings.setPrivacyMode(PrivacyMode.online)).called(1);
        await tester.tap(find.text('Offline only'));
        verify(() => settings.setPrivacyMode(PrivacyMode.offlineOnly))
            .called(1);
      });

      testWidgets('ignores the current mode', (tester) async {
        await pump(tester);
        await tester.tap(find.text('Offline first'));
        verifyNever(() => settings.setPrivacyMode(any()));
      });
    });

    testWidgets('toggles incognito', (tester) async {
      await pump(tester);
      expect(
        find.text(
          "Don't save history, and ask keyboards not to learn what you type",
        ),
        findsOneWidget,
      );
      await tester.tap(find.text('Incognito'));
      verify(() => settings.setIncognito(enabled: true)).called(1);
    });

    testWidgets('toggles the screen protection on Android', (tester) async {
      await pump(tester, const AppSettings(secureScreen: true));
      expect(PrivacySettingsSection.secureScreenSupported, isTrue);
      await tester.tap(
        find.text('Hide content in recents & block screenshots'),
      );
      verify(() => settings.setSecureScreen(enabled: false)).called(1);
    });

    testWidgets('hides the screen protection elsewhere', (tester) async {
      debugDefaultTargetPlatformOverride = TargetPlatform.linux;
      await pump(tester);
      expect(PrivacySettingsSection.secureScreenSupported, isFalse);
      expect(
        find.text('Hide content in recents & block screenshots'),
        findsNothing,
      );
      debugDefaultTargetPlatformOverride = null;
    });

    testWidgets('shows saving and auto-deleting history', (tester) async {
      await pump(
        tester,
        const AppSettings(historyRetention: HistoryRetention.month),
      );
      expect(find.text('Save history'), findsOneWidget);
      expect(find.text('Delete history automatically'), findsOneWidget);
      expect(find.text('After 30 days'), findsOneWidget);
      await tester.tap(find.text('Save history'));
      verify(() => settings.setSaveHistory(enabled: false)).called(1);
    });

    group('network pairs', () {
      testWidgets('says when none is allowed', (tester) async {
        await pump(tester);
        expect(find.text('Allowed for the network'), findsOneWidget);
        expect(find.textContaining('No language pairs yet'), findsOneWidget);
        expect(
          find.descendant(
            of: find.byKey(const Key('settings_network_pairs')),
            matching: find.byType(TextButton),
          ),
          findsNothing,
        );
      });

      testWidgets('counts and clears them, with undo', (tester) async {
        await pump(tester, const AppSettings(networkPairs: ['de>en', 'fr>en']));
        expect(
          find.text('2 language pairs may use online engines without asking'),
          findsOneWidget,
        );
        expect(
          find.bySemanticsLabel('Clear allowed language pairs'),
          findsOneWidget,
        );

        await tester.tap(find.text('Clear'));
        await tester.pump();
        verify(settings.clearNetworkPairs).called(1);
        expect(find.text('Allowed language pairs cleared'), findsOneWidget);

        await tester.pumpAndSettle();
        await tester.tap(find.text('Undo'));
        await tester.pump();
        final change =
            verify(() => settings.update(captureAny())).captured.single
                as AppSettings Function(AppSettings);
        expect(
          change(const AppSettings(networkPairs: ['es>en'])).networkPairs,
          ['es>en', 'de>en', 'fr>en'],
        );
      });

      testWidgets('says 1 pair', (tester) async {
        await pump(tester, const AppSettings(networkPairs: ['de>en']));
        expect(
          find.text('1 language pair may use online engines without asking'),
          findsOneWidget,
        );
      });
    });

    group('cloud providers', () {
      testWidgets('says when none is allowed', (tester) async {
        await pump(tester);
        expect(find.text('Cloud providers you allowed'), findsOneWidget);
        expect(
          find.text(
            "None. You're asked before text first goes to a cloud provider.",
          ),
          findsOneWidget,
        );
        expect(find.text('Revoke'), findsNothing);
      });

      testWidgets('lists them by name and revokes, with undo', (tester) async {
        await pump(
          tester,
          const AppSettings(
            providers: [_claude],
            consentedProviders: ['p1', 'gone'],
          ),
        );
        expect(find.text('Claude'), findsOneWidget);
        expect(find.text('gone'), findsOneWidget);
        expect(
          find.bySemanticsLabel('Revoke permission for Claude'),
          findsOneWidget,
        );

        await tester.tap(find.bySemanticsLabel('Revoke permission for Claude'));
        await tester.pump();
        verify(() => settings.revokeProviderConsent('p1')).called(1);
        expect(
          find.text('Claude will ask again before your text is sent'),
          findsOneWidget,
        );

        await tester.pumpAndSettle();
        await tester.tap(find.text('Undo'));
        await tester.pump();
        verify(() => settings.consentToProvider('p1')).called(1);
      });
    });

    group('HTTP proxy', () {
      Future<void> open(WidgetTester tester) async {
        await tester.tap(find.text('HTTP proxy'));
        await tester.pumpAndSettle();
      }

      testWidgets('is off by default', (tester) async {
        await pump(tester);
        expect(find.text('Off: direct connections'), findsOneWidget);
      });

      testWidgets('saves a proxy and says when it applies', (tester) async {
        await pump(tester);
        await open(tester);
        expect(find.textContaining("Orbot's HTTP proxy"), findsOneWidget);
        expect(find.text('Applies after restarting the app.'), findsOneWidget);

        await tester.enterText(
          find.byKey(const Key('settings_http_proxy_field')),
          '127.0.0.1:8118',
        );
        await tester.tap(find.text('Save'));
        await tester.pumpAndSettle();

        verify(() => settings.setHttpProxy('127.0.0.1:8118')).called(1);
        expect(
          find.text('Proxy saved. Restart the app to use it.'),
          findsOneWidget,
        );
      });

      testWidgets('shows the proxy and removes it', (tester) async {
        await pump(tester, const AppSettings(httpProxy: '10.0.0.2:3128'));
        expect(find.text('10.0.0.2:3128'), findsOneWidget);
        await open(tester);
        await tester.tap(find.text('Remove'));
        await tester.pumpAndSettle();

        verify(() => settings.setHttpProxy(null)).called(1);
        expect(
          find.text('Proxy removed. Restart the app to connect directly.'),
          findsOneWidget,
        );
      });

      testWidgets('changes nothing when cancelled or unchanged', (
        tester,
      ) async {
        await pump(tester, const AppSettings(httpProxy: '10.0.0.2:3128'));
        await open(tester);
        await tester.tap(find.text('Cancel'));
        await tester.pumpAndSettle();
        await open(tester);
        await tester.tap(find.text('Save'));
        await tester.pumpAndSettle();

        verifyNever(() => settings.setHttpProxy(any()));
      });
    });

    testWidgets('offers to delete all local data', (tester) async {
      await pump(tester);
      expect(find.text('Delete all local data'), findsOneWidget);
      expect(
        find.text('History, settings, caches, offline models and API keys'),
        findsOneWidget,
      );
      await tester.tap(find.text('Delete all local data'));
      await tester.pumpAndSettle();
      expect(find.text('Delete all local data?'), findsOneWidget);
    });
  });
}
