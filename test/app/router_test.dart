import 'package:flutter_test/flutter_test.dart';
import 'package:go_router/go_router.dart';
import 'package:material_ui/material_ui.dart';
import 'package:mozhi/app/router.dart';
import 'package:mozhi/app/translate_link.dart';
import 'package:mozhi/app/view/app_shell.dart';
import 'package:mozhi/history/view/history_page.dart';
import 'package:mozhi/l10n/l10n.dart';
import 'package:mozhi/proofread/view/proofread_page.dart';
import 'package:mozhi/settings/view/about_page.dart';
import 'package:mozhi/settings/view/instances_page.dart';
import 'package:mozhi/settings/view/provider_editor_page.dart';
import 'package:mozhi/settings/view/providers_page.dart';
import 'package:mozhi/settings/view/settings_page.dart';
import 'package:mozhi/translate/view/translate_page.dart';

import 'mocks.dart';

void main() {
  setUpAll(registerAppFallbacks);

  group('AppRoutes', () {
    test('editProvider builds the editor location', () {
      expect(AppRoutes.editProvider(), '/settings/providers/edit');
      expect(
        AppRoutes.editProvider(id: 'a b'),
        '/settings/providers/edit?id=a+b',
      );
      expect(
        AppRoutes.editProvider(preset: 'ollama'),
        '/settings/providers/edit?preset=ollama',
      );
    });

    test('translateText builds a Kagi-style link', () {
      expect(
        AppRoutes.translateText(text: 'hola', from: 'es', to: 'en'),
        '/translate?text=hola&from=es&to=en',
      );
      expect(AppRoutes.translateText(), '/translate');
    });
  });

  group('appRedirect', () {
    late List<TranslateLink> links;

    setUp(() => links = []);

    String? redirect(String location) =>
        appRedirect(Uri.parse(location), links.add);

    test('sends the root to /translate', () {
      expect(redirect('/'), AppRoutes.translate);
      expect(redirect(''), AppRoutes.translate);
      expect(links, isEmpty);
    });

    test('reports translate links and strips them', () {
      expect(redirect('/translate?text=hi&to=fr'), AppRoutes.translate);
      expect(redirect('/?q=hola'), AppRoutes.translate);
      expect(links, const [
        TranslateLink(text: 'hi', to: 'fr'),
        TranslateLink(text: 'hola'),
      ]);
    });

    test('leaves other locations alone', () {
      expect(redirect('/translate'), isNull);
      expect(redirect('/translate?unrelated=1'), isNull);
      expect(redirect('/history?text=hi'), isNull);
      expect(redirect('/settings/providers/edit?id=x'), isNull);
      expect(links, isEmpty);
    });

    test('works without a callback', () {
      expect(
        appRedirect(Uri.parse('/translate?text=hi'), null),
        AppRoutes.translate,
      );
    });
  });

  group('createAppRouter', () {
    late TestEnvironment env;
    late List<TranslateLink> links;
    late GoRouter router;

    setUp(() {
      env = TestEnvironment();
      links = [];
      router = createAppRouter(onTranslateLink: links.add);
    });

    tearDown(() => router.dispose());

    Future<void> pumpRouter(WidgetTester tester, {double width = 400}) async {
      tester.view.physicalSize = Size(width, 900);
      tester.view.devicePixelRatio = 1;
      addTearDown(tester.view.reset);
      await tester.pumpWidget(
        env.wrap(
          MaterialApp.router(
            routerConfig: router,
            localizationsDelegates: AppLocalizations.localizationsDelegates,
            supportedLocales: AppLocalizations.supportedLocales,
          ),
        ),
      );
      await tester.pump();
    }

    Future<void> go(WidgetTester tester, String location) async {
      router.go(location);
      await tester.pump();
      await tester.pump(const Duration(milliseconds: 400));
    }

    String location() =>
        router.routerDelegate.currentConfiguration.uri.toString();

    testWidgets('starts on the translate tab', (tester) async {
      await pumpRouter(tester);

      expect(location(), '/translate');
      expect(find.byType(TranslatePage), findsOneWidget);
      expect(find.byType(AppShell), findsOneWidget);
      expect(find.byType(NavigationBar), findsOneWidget);
    });

    final pages = <String, Type>{
      '/proofread': ProofreadPage,
      '/history': HistoryPage,
      '/settings': SettingsPage,
      '/settings/instances': InstancesPage,
      '/settings/providers': ProvidersPage,
      '/settings/providers/edit': ProviderEditorPage,
      '/settings/about': AboutPage,
      '/translate': TranslatePage,
    };
    for (final MapEntry(key: path, value: page) in pages.entries) {
      testWidgets('builds $path', (tester) async {
        await pumpRouter(tester);
        await go(tester, path);

        expect(location(), path);
        expect(find.byType(page), findsOneWidget);
        expect(find.byType(AppShell), findsOneWidget);
      });
    }

    testWidgets('passes provider editor query parameters', (tester) async {
      await pumpRouter(tester);
      await go(tester, AppRoutes.editProvider(id: 'p1'));

      var editor = tester.widget<ProviderEditorPage>(
        find.byType(ProviderEditorPage),
      );
      expect(editor.providerId, 'p1');
      expect(editor.presetId, isNull);

      await go(tester, AppRoutes.editProvider(preset: 'ollama'));
      editor = tester.widget<ProviderEditorPage>(
        find.byType(ProviderEditorPage),
      );
      expect(editor.providerId, isNull);
      expect(editor.presetId, 'ollama');
    });

    testWidgets('switches tabs from the navigation bar', (tester) async {
      await pumpRouter(tester);

      await tester.tap(
        find.descendant(
          of: find.byType(NavigationBar),
          matching: find.text('History'),
        ),
      );
      await tester.pump();
      await tester.pump(const Duration(milliseconds: 400));

      expect(location(), '/history');
      expect(find.byType(HistoryPage), findsOneWidget);
    });

    testWidgets("keeps each tab's stack and pops on re-tap", (tester) async {
      await pumpRouter(tester);
      await go(tester, '/settings/about');

      await tester.tap(
        find.descendant(
          of: find.byType(NavigationBar),
          matching: find.text('Translate'),
        ),
      );
      await tester.pump();
      expect(location(), '/translate');

      Future<void> tapSettings() async {
        await tester.tap(
          find.descendant(
            of: find.byType(NavigationBar),
            matching: find.text('Settings'),
          ),
        );
        await tester.pump();
        await tester.pump(const Duration(milliseconds: 400));
      }

      await tapSettings();
      expect(location(), '/settings/about');

      await tapSettings();
      expect(location(), '/settings');
    });

    testWidgets('uses a navigation rail on wide screens', (tester) async {
      await pumpRouter(tester, width: 1200);

      expect(find.byType(NavigationRail), findsOneWidget);
      expect(find.byType(NavigationBar), findsNothing);
    });

    testWidgets('hands translate links to the callback', (tester) async {
      await pumpRouter(tester);
      await go(tester, '/history');
      await go(tester, '/translate?text=hola&from=es&to=en');

      expect(location(), '/translate');
      expect(links, const [TranslateLink(text: 'hola', from: 'es', to: 'en')]);
      expect(find.byType(TranslatePage), findsOneWidget);
    });

    testWidgets('sends unknown locations to /translate', (tester) async {
      await pumpRouter(tester);
      await go(tester, '/does/not/exist');
      await tester.pump();

      expect(location(), '/translate');
    });
  });
}
