import 'dart:async';

import 'package:flutter_test/flutter_test.dart';
import 'package:go_router/go_router.dart';
import 'package:material_ui/material_ui.dart';
import 'package:mocktail/mocktail.dart';
import 'package:mozhi/app/router.dart';
import 'package:mozhi/app/translate_link.dart';
import 'package:mozhi/app/view/app_shell.dart';
import 'package:mozhi/conversation/view/conversation_page.dart';
import 'package:mozhi/documents/view/document_translate_page.dart';
import 'package:mozhi/history/view/history_page.dart';
import 'package:mozhi/image_translate/models/picked_image.dart';
import 'package:mozhi/image_translate/view/image_translate_page.dart';
import 'package:mozhi/l10n/l10n.dart';
import 'package:mozhi/offline/view/offline_models_page.dart';
import 'package:mozhi/onboarding/view/onboarding_page.dart';
import 'package:mozhi/presets/view/glossaries_page.dart';
import 'package:mozhi/presets/view/presets_page.dart';
import 'package:mozhi/proofread/view/proofread_page.dart';
import 'package:mozhi/settings/models/app_settings.dart';
import 'package:mozhi/settings/view/about_page.dart';
import 'package:mozhi/settings/view/instances_page.dart';
import 'package:mozhi/settings/view/provider_editor_page.dart';
import 'package:mozhi/settings/view/providers_page.dart';
import 'package:mozhi/settings/view/settings_page.dart';
import 'package:mozhi/translate/view/translate_page.dart';
import 'package:mozhi/usage/view/usage_summary_page.dart';
import 'package:mozhi/web_translate/view/web_translate_page.dart';
import 'package:translation_repository/translation_repository.dart';

import 'mocks.dart';

/// Longer than any page transition (Android's is 800 ms).
const _transition = Duration(seconds: 1);

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

    test('imageTranslate and webPage build their locations', () {
      expect(AppRoutes.imageTranslate(), '/image');
      expect(
        AppRoutes.imageTranslate(source: ImagePickSource.camera),
        '/image?source=camera',
      );
      expect(AppRoutes.webPage(), '/web');
      expect(AppRoutes.webPage(url: '  '), '/web');
      expect(
        AppRoutes.webPage(url: ' https://example.com/a?b=1 '),
        '/web?url=https%3A%2F%2Fexample.com%2Fa%3Fb%3D1',
      );
    });

    test('onboarding is outside the settings', () {
      expect(AppRoutes.onboarding, '/onboarding');
    });
  });

  group('isLaunchLocation', () {
    test('accepts the plain start locations', () {
      expect(isLaunchLocation(Uri.parse('/')), isTrue);
      expect(isLaunchLocation(Uri.parse('')), isTrue);
      expect(isLaunchLocation(Uri.parse('/translate')), isTrue);
    });

    test('rejects deep links and other locations', () {
      expect(isLaunchLocation(Uri.parse('/translate?text=hi')), isFalse);
      expect(isLaunchLocation(Uri.parse('/?q=hi')), isFalse);
      expect(isLaunchLocation(Uri.parse('/translate?')), isFalse);
      expect(isLaunchLocation(Uri.parse('/history')), isFalse);
      expect(isLaunchLocation(Uri.parse('/image')), isFalse);
      expect(isLaunchLocation(Uri.parse('/onboarding')), isFalse);
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

    test('sends feature aliases to their routes, keeping the query', () {
      expect(redirect('/translate/image'), AppRoutes.image);
      expect(
        redirect('/translate/image?source=gallery'),
        '/image?source=gallery',
      );
      expect(
        redirect('/translate/web?url=https%3A%2F%2Fa.test'),
        '/web?url=https%3A%2F%2Fa.test',
      );
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
    late List<String> launches;

    setUp(() {
      env = TestEnvironment();
      links = [];
      launches = [];
      router = createAppRouter(onTranslateLink: links.add);
    });

    tearDown(() => router.dispose());

    /// A router whose launch redirect sends to the onboarding.
    GoRouter onboardingRouter({String initialLocation = AppRoutes.translate}) {
      router.dispose();
      return router = createAppRouter(
        onTranslateLink: links.add,
        initialLocation: initialLocation,
        launchRedirect: (location) {
          launches.add(location);
          return AppRoutes.onboarding;
        },
      );
    }

    Future<void> pumpRouter(WidgetTester tester, {double width = 400}) async {
      tester.view.physicalSize = Size(width, 900);
      tester.view.devicePixelRatio = 1;
      addTearDown(tester.view.reset);
      await tester.pumpWidget(
        env.wrap(
          MaterialApp.router(
            routerConfig: router,
            localizationsDelegates: appLocalizationsDelegates,
            supportedLocales: AppLocalizations.supportedLocales,
          ),
        ),
      );
      await tester.pump();
    }

    Future<void> go(WidgetTester tester, String location) async {
      router.go(location);
      await tester.pump();
      await tester.pump(_transition);
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
      '/settings/offline': OfflineModelsPage,
      '/settings/presets': PresetsPage,
      '/settings/glossaries': GlossariesPage,
      '/settings/usage': UsageSummaryPage,
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

    final fullScreenPages = <String, Type>{
      '/onboarding': OnboardingPage,
      '/image': ImageTranslatePage,
      '/documents': DocumentTranslatePage,
      '/web': WebTranslatePage,
      '/conversation': ConversationPage,
    };
    for (final MapEntry(key: path, value: page) in fullScreenPages.entries) {
      testWidgets('builds $path full screen', (tester) async {
        await pumpRouter(tester);
        await go(tester, path);

        expect(location(), path);
        expect(find.byType(page), findsOneWidget);
        expect(find.byType(AppShell), findsNothing);
      });
    }

    testWidgets('pushes full-screen pages above the tabs', (tester) async {
      await pumpRouter(tester);

      unawaited(router.push<void>(AppRoutes.documents));
      await tester.pump();
      await tester.pump(_transition);

      expect(find.byType(DocumentTranslatePage), findsOneWidget);
      expect(find.byType(AppShell, skipOffstage: false), findsOneWidget);
      expect(find.byType(NavigationBar).hitTestable(), findsNothing);

      router.pop();
      await tester.pump();
      await tester.pump(_transition);

      expect(find.byType(DocumentTranslatePage), findsNothing);
      expect(find.byType(NavigationBar).hitTestable(), findsOneWidget);
      expect(location(), AppRoutes.translate);
    });

    testWidgets('opens feature aliases at their routes', (tester) async {
      await pumpRouter(tester);
      await go(tester, '/translate/image?source=gallery');

      expect(location(), '/image?source=gallery');
      final page = tester.widget<ImageTranslatePage>(
        find.byType(ImageTranslatePage),
      );
      expect(page.initialSource, ImagePickSource.gallery);
    });

    testWidgets('passes the web page address', (tester) async {
      await pumpRouter(tester);
      await go(tester, '/translate/web?url=https%3A%2F%2Fexample.test');

      expect(location(), '/web?url=https%3A%2F%2Fexample.test');
      final page = tester.widget<WebTranslatePage>(
        find.byType(WebTranslatePage),
      );
      expect(page.initialUrl, 'https://example.test');
    });

    testWidgets('presets open the glossaries', (tester) async {
      await pumpRouter(tester);
      await go(tester, AppRoutes.presets);

      final page = tester.widget<PresetsPage>(find.byType(PresetsPage));
      page.onOpenGlossaries!();
      await tester.pump();
      await tester.pump(_transition);

      expect(find.byType(GlossariesPage), findsOneWidget);
      expect(find.byType(AppShell), findsOneWidget);
    });

    testWidgets('usage lists the providers and opens their editor', (
      tester,
    ) async {
      const provider = AiProviderConfig(
        id: 'p1',
        name: 'P1',
        provider: LlmProvider.openAiCompatible,
        baseUrl: 'http://localhost',
        model: 'm',
      );
      when(() => env.settingsCubit.state).thenReturn(
        const AppSettings(instances: [testInstance], providers: [provider]),
      );
      await pumpRouter(tester);
      await go(tester, AppRoutes.usage);

      final page = tester.widget<UsageSummaryPage>(
        find.byType(UsageSummaryPage),
      );
      expect(page.providers, const [provider]);
      page.onOpenProvider!('p1');
      await tester.pump();
      await tester.pump(_transition);

      final editor = tester.widget<ProviderEditorPage>(
        find.byType(ProviderEditorPage),
      );
      expect(editor.providerId, 'p1');
    });

    group('launch redirect', () {
      testWidgets('sends a plain start to the onboarding once', (tester) async {
        onboardingRouter();
        await pumpRouter(tester);
        await tester.pump(_transition);

        expect(location(), AppRoutes.onboarding);
        expect(find.byType(OnboardingPage), findsOneWidget);
        expect(launches, [AppRoutes.translate]);

        await go(tester, AppRoutes.translate);
        expect(location(), AppRoutes.translate);
        expect(find.byType(TranslatePage), findsOneWidget);
        expect(launches, hasLength(1));
      });

      testWidgets('also applies to the root', (tester) async {
        onboardingRouter(initialLocation: '/');
        await pumpRouter(tester);

        expect(location(), AppRoutes.onboarding);
      });

      testWidgets('never redirects translate links', (tester) async {
        onboardingRouter(initialLocation: '/translate?text=hola&to=en');
        await pumpRouter(tester);

        expect(location(), AppRoutes.translate);
        expect(launches, isEmpty);
        expect(links, const [TranslateLink(text: 'hola', to: 'en')]);
      });

      testWidgets('never redirects other deep links', (tester) async {
        onboardingRouter(initialLocation: AppRoutes.history);
        await pumpRouter(tester);
        await go(tester, AppRoutes.translate);

        expect(location(), AppRoutes.translate);
        expect(launches, isEmpty);
      });

      testWidgets('keeps the start location when it returns null', (
        tester,
      ) async {
        router.dispose();
        router = createAppRouter(launchRedirect: (_) => null);
        await pumpRouter(tester);

        expect(location(), AppRoutes.translate);
      });
    });

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
      await tester.pump(_transition);

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
        await tester.pump(_transition);
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
