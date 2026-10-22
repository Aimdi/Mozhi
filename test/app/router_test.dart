import 'dart:async';
import 'dart:io';

import 'package:flutter/services.dart';
import 'package:flutter_bloc/flutter_bloc.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:go_router/go_router.dart';
import 'package:material_ui/material_ui.dart';
import 'package:mocktail/mocktail.dart';
import 'package:mozhi/app/router.dart';
import 'package:mozhi/app/shared_files.dart';
import 'package:mozhi/app/translate_link.dart';
import 'package:mozhi/app/view/app_shell.dart';
import 'package:mozhi/app/view/shared_image_picker.dart';
import 'package:mozhi/app/view/top_level_actions.dart';
import 'package:mozhi/conversation/view/conversation_page.dart';
import 'package:mozhi/dictionary/view/dictionary_page.dart';
import 'package:mozhi/documents/view/document_translate_page.dart';
import 'package:mozhi/history/view/history_page.dart';
import 'package:mozhi/image_translate/cubit/image_translate_cubit.dart';
import 'package:mozhi/image_translate/models/picked_image.dart';
import 'package:mozhi/image_translate/view/image_translate_page.dart';
import 'package:mozhi/l10n/l10n.dart';
import 'package:mozhi/offline/view/offline_models_page.dart';
import 'package:mozhi/onboarding/view/onboarding_page.dart';
import 'package:mozhi/presets/view/glossaries_page.dart';
import 'package:mozhi/presets/view/presets_page.dart';
import 'package:mozhi/proofread/view/proofread_page.dart';
import 'package:mozhi/quick_translate/quick_translate_host.dart';
import 'package:mozhi/settings/models/app_settings.dart';
import 'package:mozhi/settings/view/about_page.dart';
import 'package:mozhi/settings/view/instances_page.dart';
import 'package:mozhi/settings/view/network_activity_page.dart';
import 'package:mozhi/settings/view/provider_editor_page.dart';
import 'package:mozhi/settings/view/providers_page.dart';
import 'package:mozhi/settings/view/quality_modes_page.dart';
import 'package:mozhi/settings/view/settings_page.dart';
import 'package:mozhi/settings/view/tab_order_page.dart';
import 'package:mozhi/settings/view/voice_input_settings_page.dart';
import 'package:mozhi/translate/cubit/translate_cubit.dart';
import 'package:mozhi/translate/view/translate_page.dart';
import 'package:mozhi/usage/view/usage_summary_page.dart';
import 'package:mozhi/web_translate/cubit/web_translate_cubit.dart';
import 'package:mozhi/web_translate/view/web_translate_page.dart';
import 'package:translation_repository/translation_repository.dart';

import 'mocks.dart';

/// Longer than any page transition (Android's is 800 ms).
const _transition = Duration(seconds: 1);

void main() {
  setUpAll(() async {
    registerAppFallbacks();
    // The deferred screens are loaded on first use (DeferredPage); load
    // them up front so the routes build synchronously as before.
    await Future.wait(DeferredFeatures.all.map((library) => library.load()));
  });

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

    test('proofreadText and dictionaryWord build their links', () {
      expect(AppRoutes.proofreadText(), '/proofread');
      expect(
        AppRoutes.proofreadText(text: 'I has a cat'),
        '/proofread?text=I+has+a+cat',
      );
      expect(AppRoutes.dictionaryWord(), '/dictionary');
      expect(
        AppRoutes.dictionaryWord(word: 'gato', from: 'es', to: 'en'),
        '/dictionary?word=gato&from=es&to=en',
      );
    });

    test('onboarding is outside the settings', () {
      expect(AppRoutes.onboarding, '/onboarding');
    });

    test('network activity, the quick window and shared files', () {
      expect(AppRoutes.networkActivity, '/settings/network');
      expect(AppRoutes.quickTranslate, QuickTranslateHost.location);
      expect(AppRoutes.sharedImage('ab'), '/image?shared=ab');
      expect(AppRoutes.sharedDocument('ab'), '/documents?shared=ab');
    });

    test('tab maps every tab to its location', () {
      expect(
        [for (final tab in AppTab.values) AppRoutes.tab(tab)],
        [
          AppRoutes.translate,
          AppRoutes.dictionary,
          AppRoutes.proofread,
          AppRoutes.conversation,
        ],
      );
      expect(AppRoutes.tabOrder, '/settings/tabs');
    });
  });

  group('homeRedirect', () {
    test('opens the translate tab in the default order', () {
      expect(homeRedirect(const AppSettings(), '/'), AppRoutes.translate);
      expect(homeRedirect(const AppSettings(), AppRoutes.translate), isNull);
    });

    test('sends a plain start to the first tab of the order', () {
      const settings = AppSettings(
        tabOrder: [
          AppTab.proofread,
          AppTab.translate,
          AppTab.dictionary,
          AppTab.conversation,
        ],
      );
      expect(homeRedirect(settings, '/'), AppRoutes.proofread);
      expect(homeRedirect(settings, ''), AppRoutes.proofread);
      expect(homeRedirect(settings, AppRoutes.proofread), isNull);
    });

    test('keeps an explicit start at the translate tab', () {
      const settings = AppSettings(
        tabOrder: [
          AppTab.dictionary,
          AppTab.translate,
          AppTab.proofread,
          AppTab.conversation,
        ],
      );
      expect(homeRedirect(settings, AppRoutes.translate), isNull);
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
      expect(isLaunchLocation(Uri.parse('mozhi://image')), isFalse);
      expect(isLaunchLocation(Uri.parse('mozhi://translate/')), isFalse);
      expect(isLaunchLocation(Uri.parse('mozhi:///translate')), isFalse);
    });
  });

  group('deepLinkLocation', () {
    test('maps the host to the first path segment', () {
      expect(
        deepLinkLocation(Uri.parse('mozhi://dictionary?word=gato&from=es')),
        '/dictionary?word=gato&from=es',
      );
      expect(deepLinkLocation(Uri.parse('mozhi://image')), '/image');
      expect(deepLinkLocation(Uri.parse('mozhi://image/')), '/image');
      expect(
        deepLinkLocation(Uri.parse('mozhi://settings/providers/edit?id=p1')),
        '/settings/providers/edit?id=p1',
      );
    });

    test('keeps the percent-encoding of the query', () {
      expect(
        deepLinkLocation(Uri.parse('mozhi://proofread?text=I%20has%26a')),
        '/proofread?text=I%20has%26a',
      );
    });

    test('ignores case in the scheme and the screen', () {
      expect(
        deepLinkLocation(Uri.parse('MOZHI://Translate?text=Hola')),
        '/translate?text=Hola',
      );
    });

    test('handles links without a host or an empty query', () {
      expect(
        deepLinkLocation(Uri.parse('mozhi:///settings/about')),
        '/settings/about',
      );
      expect(deepLinkLocation(Uri.parse('mozhi:')), '/');
      expect(deepLinkLocation(Uri.parse('mozhi://web?')), '/web');
    });

    test('ignores other locations', () {
      expect(deepLinkLocation(Uri.parse('/translate?text=hi')), isNull);
      expect(deepLinkLocation(Uri.parse('https://mozhi.test/image')), isNull);
      expect(deepLinkLocation(Uri.parse('intent://translate')), isNull);
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

    test('sends deep links to their location first', () {
      expect(
        redirect('mozhi://translate?text=hi&to=fr'),
        '/translate?text=hi&to=fr',
      );
      expect(redirect('mozhi://dictionary?word=x'), '/dictionary?word=x');
      expect(links, isEmpty);
    });

    test('reports translate links with options', () {
      expect(
        redirect('/translate?formality=formal&quality=best'),
        AppRoutes.translate,
      );
      expect(links, const [
        TranslateLink(
          options: TranslationOptions(formality: Formality.more),
          quality: TranslateLinkQuality.best,
        ),
      ]);
    });

    test('leaves proofread and dictionary links alone', () {
      expect(redirect('/proofread?text=hi'), isNull);
      expect(redirect('/dictionary?word=hi'), isNull);
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
    GoRouter onboardingRouter({String initialLocation = '/'}) {
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

    final tabs = <String, Type>{
      '/translate': TranslatePage,
      '/dictionary': DictionaryPage,
      '/proofread': ProofreadPage,
      '/conversation': ConversationPage,
    };
    for (final MapEntry(key: path, value: page) in tabs.entries) {
      testWidgets('builds the $path tab', (tester) async {
        await pumpRouter(tester);
        await go(tester, path);

        expect(location(), path);
        expect(find.byType(page), findsOneWidget);
        expect(find.byType(AppShell), findsOneWidget);
        // History and Settings are in every tab's app bar.
        expect(find.byType(TopLevelActions), findsOneWidget);
      });
    }

    final fullScreenPages = <String, Type>{
      '/onboarding': OnboardingPage,
      '/image': ImageTranslatePage,
      '/documents': DocumentTranslatePage,
      '/web': WebTranslatePage,
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
      '/settings/quality': QualityModesPage,
      '/settings/tabs': TabOrderPage,
      '/settings/network': NetworkActivityPage,
      AppRoutes.voiceSettings: VoiceInputSettingsPage,
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

    group('quick translate window', () {
      testWidgets('shows only its transparent page there', (tester) async {
        router.dispose();
        router = createAppRouter(
          quickTranslateWindow: true,
          launchRedirect: (_) => AppRoutes.onboarding,
        );
        await pumpRouter(tester);

        expect(location(), AppRoutes.quickTranslate);
        expect(find.byType(QuickTranslateHostView), findsOneWidget);
        expect(find.byType(AppShell), findsNothing);

        await go(tester, AppRoutes.settings);
        expect(location(), AppRoutes.quickTranslate);
        await go(tester, AppRoutes.translateText(text: 'hola'));
        expect(location(), AppRoutes.quickTranslate);
        expect(links, isEmpty);
      });

      testWidgets('the main window never shows it', (tester) async {
        await pumpRouter(tester);
        await go(tester, AppRoutes.quickTranslate);

        expect(location(), AppRoutes.translate);
        expect(find.byType(QuickTranslateHostView), findsNothing);
      });
    });

    group('shared files', () {
      const token = '0123456789abcdef0123456789abcdef';
      const pathProvider = MethodChannel('plugins.flutter.io/path_provider');
      late Directory cache;

      setUp(() {
        cache = Directory.systemTemp.createTempSync('router_shared');
        TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger
            .setMockMethodCallHandler(pathProvider, (call) async => cache.path);
      });

      tearDown(() {
        TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger
            .setMockMethodCallHandler(pathProvider, null);
        cache.deleteSync(recursive: true);
      });

      void share(String name, List<int> bytes) {
        final folder = Directory('${cache.path}/${SharedFiles.folder}/$token')
          ..createSync(recursive: true);
        File('${folder.path}/$name').writeAsBytesSync(bytes);
      }

      Future<void> open(WidgetTester tester, String location) async {
        await pumpRouter(tester);
        router.go(location);
        await tester.pump();
        // Reading the file is real I/O.
        for (var i = 0; i < 30; i++) {
          await tester.runAsync(
            () => Future<void>.delayed(const Duration(milliseconds: 5)),
          );
          await tester.pump();
        }
        await tester.pump(_transition);
      }

      testWidgets('a shared document opens in the document translator', (
        tester,
      ) async {
        share('talk.srt', '1\n00:00:01,000 --> 00:00:02,000\nHola\n'.codeUnits);
        await open(tester, AppRoutes.sharedDocument(token));

        final page = tester.widget<DocumentTranslatePage>(
          find.byType(DocumentTranslatePage),
        );
        expect(page.initialFile!.name, 'talk.srt');
        expect(String.fromCharCodes(page.initialFile!.bytes), contains('Hola'));
        // Nothing is translated until the user asks.
        verifyNever(() => env.translationRepository.translate(any(), any()));
      });

      testWidgets('an unknown token opens the empty document translator', (
        tester,
      ) async {
        await open(tester, AppRoutes.sharedDocument(token));
        final page = tester.widget<DocumentTranslatePage>(
          find.byType(DocumentTranslatePage),
        );
        expect(page.initialFile, isNull);
      });

      testWidgets('a malformed token is no shared file', (tester) async {
        await pumpRouter(tester);
        await go(tester, '/documents?shared=../secret');
        expect(
          tester
              .widget<DocumentTranslatePage>(find.byType(DocumentTranslatePage))
              .initialFile,
          isNull,
        );
        await go(tester, '/image?shared=../secret');
        expect(
          tester
              .widget<ImageTranslatePage>(find.byType(ImageTranslatePage))
              .picker,
          isNull,
        );
      });

      testWidgets('a shared image is handed to the image translator', (
        tester,
      ) async {
        share('shot.png', const [0x89, 0x50, 0x4E, 0x47]);
        await open(tester, AppRoutes.sharedImage(token));

        final page = tester.widget<ImageTranslatePage>(
          find.byType(ImageTranslatePage),
        );
        expect(page.picker, isA<SharedImagePicker>());
        // The screen took it on arrival.
        final image = tester
            .element(find.byType(ImageTranslateView))
            .read<ImageTranslateCubit>()
            .state
            .image;
        expect(image!.name, 'shot.png');
        expect(image.mimeType, 'image/png');
        // Kept for on-device text recognition.
        expect(File(image.path!).existsSync(), isTrue);
      });

      testWidgets('waits for the user when an AI model would translate it', (
        tester,
      ) async {
        const claude = TranslationEngine(
          id: 'ai:claude',
          kind: EngineKind.ai,
          name: 'Claude',
          providerId: 'claude',
        );
        when(() => env.translateCubit.state).thenReturn(
          const TranslateState(
            enginesStatus: EnginesStatus.ready,
            engines: [claude],
            engine: claude,
          ),
        );
        share('shot.png', const [0x89, 0x50, 0x4E, 0x47]);
        await open(tester, AppRoutes.sharedImage(token));

        final page = tester.widget<ImageTranslatePage>(
          find.byType(ImageTranslatePage),
        );
        expect(page.picker, isNull);
      });
    });

    WebTranslateState webState(WidgetTester tester) => tester
        .element(find.byType(WebTranslateView))
        .read<WebTranslateCubit>()
        .state;

    testWidgets('web page links only fill in the address', (tester) async {
      await pumpRouter(tester);
      await go(tester, '/translate/web?url=https%3A%2F%2Fexample.test');

      expect(location(), '/web?url=https%3A%2F%2Fexample.test');
      expect(
        tester.widget<WebTranslatePage>(find.byType(WebTranslatePage)).autoLoad,
        isFalse,
      );
      expect(find.byType(WebTranslateView), findsOneWidget);
      expect(find.byType(AppShell), findsNothing);
      final state = webState(tester);
      expect(state.url, 'https://example.test');
      expect(state.status, WebTranslateStatus.idle);
      final field = tester.widget<TextField>(
        find.byKey(const Key('web_translate_url_field')),
      );
      expect(field.controller!.text, 'https://example.test');

      await go(tester, AppRoutes.webPage(url: 'https://other.test'));
      expect(webState(tester).url, 'https://other.test');
      expect(webState(tester).status, WebTranslateStatus.idle);
    });

    testWidgets('loads the web page right away only when the app asks', (
      tester,
    ) async {
      await pumpRouter(tester);

      unawaited(
        router.push<void>(
          AppRoutes.webPage(url: 'https://example.test'),
          extra: WebPageLaunch.load,
        ),
      );
      await tester.pump();
      await tester.pump(_transition);

      final page = tester.widget<WebTranslatePage>(
        find.byType(WebTranslatePage),
      );
      expect(page.initialUrl, 'https://example.test');
      expect(find.byType(AppShell, skipOffstage: false), findsOneWidget);
    });

    testWidgets('passes the dictionary word and languages', (tester) async {
      await pumpRouter(tester);
      await go(tester, '/dictionary?word=gato&from=es&to=en');

      final page = tester.widget<DictionaryPage>(find.byType(DictionaryPage));
      expect(page.word, 'gato');
      expect(page.from, 'es');
      expect(page.to, 'en');
      expect(page.autoLookUp, isFalse);
    });

    testWidgets('looks up right away only when the app asks', (tester) async {
      await pumpRouter(tester);

      unawaited(
        router.push<void>(
          AppRoutes.dictionaryWord(word: 'gato'),
          extra: DictionaryLaunch.lookUp,
        ),
      );
      await tester.pump();
      await tester.pump(_transition);

      var page = tester.widget<DictionaryPage>(find.byType(DictionaryPage));
      expect(page.word, 'gato');
      expect(page.autoLookUp, isTrue);
      expect(find.byType(AppShell, skipOffstage: false), findsOneWidget);

      await go(tester, '/dictionary?word=perro');
      page = tester.widget<DictionaryPage>(find.byType(DictionaryPage));
      expect(page.word, 'perro');
      expect(page.autoLookUp, isFalse);
    });

    testWidgets('the translate screen\'s "Open dictionary" selects the '
        'Dictionary tab and looks the word up', (tester) async {
      await pumpRouter(tester);
      // As DictionaryCard.openDictionary navigates.
      router.go(
        AppRoutes.dictionaryWord(word: 'gato', from: 'es'),
        extra: DictionaryLaunch.lookUp,
      );
      await tester.pump();
      await tester.pump(_transition);

      final page = tester.widget<DictionaryPage>(find.byType(DictionaryPage));
      expect(page.word, 'gato');
      expect(page.from, 'es');
      expect(page.autoLookUp, isTrue);
      expect(location(), '/dictionary?word=gato&from=es');
    });

    testWidgets('passes proofread link text', (tester) async {
      await pumpRouter(tester);
      await go(tester, AppRoutes.proofreadText(text: 'I has a cat'));

      final page = tester.widget<ProofreadPage>(find.byType(ProofreadPage));
      expect(page.initialText, 'I has a cat');
      expect(find.byType(AppShell), findsOneWidget);
    });

    group('deep links', () {
      testWidgets('open the dictionary', (tester) async {
        await pumpRouter(tester);
        await go(tester, 'mozhi://dictionary?word=gato&from=es');

        expect(location(), '/dictionary?word=gato&from=es');
        final page = tester.widget<DictionaryPage>(find.byType(DictionaryPage));
        expect(page.word, 'gato');
        expect(page.from, 'es');
        expect(page.autoLookUp, isFalse);
      });

      testWidgets('open proofreading with text', (tester) async {
        await pumpRouter(tester);
        await go(tester, 'mozhi://proofread?text=I%20has%20a%20cat');

        expect(Uri.parse(location()).path, AppRoutes.proofread);
        final page = tester.widget<ProofreadPage>(find.byType(ProofreadPage));
        expect(page.initialText, 'I has a cat');
      });

      testWidgets('hand translate links to the callback', (tester) async {
        await pumpRouter(tester);
        await go(tester, 'mozhi://translate?text=hola&to=en');

        expect(location(), AppRoutes.translate);
        expect(links, const [TranslateLink(text: 'hola', to: 'en')]);
      });

      testWidgets('never load a web page on their own', (tester) async {
        await pumpRouter(tester);
        await go(tester, 'mozhi://web?url=http%3A%2F%2F192.168.1.1%2F');

        expect(location(), '/web?url=http%3A%2F%2F192.168.1.1%2F');
        expect(
          tester
              .widget<WebTranslatePage>(find.byType(WebTranslatePage))
              .autoLoad,
          isFalse,
        );
        final state = webState(tester);
        expect(state.url, 'http://192.168.1.1/');
        expect(state.status, WebTranslateStatus.idle);
        verifyNever(
          () => env.translationRepository.translate(
            any(),
            any(),
            refresh: any(named: 'refresh'),
          ),
        );
      });

      testWidgets('open other screens', (tester) async {
        await pumpRouter(tester);
        await go(tester, 'mozhi://image');

        expect(location(), AppRoutes.image);
        expect(find.byType(ImageTranslatePage), findsOneWidget);
      });

      testWidgets('are never sent to the onboarding', (tester) async {
        onboardingRouter(initialLocation: 'mozhi://image');
        await pumpRouter(tester);
        await tester.pump(_transition);

        expect(location(), AppRoutes.image);
        expect(launches, isEmpty);
      });
    });

    testWidgets('presets open the glossaries', (tester) async {
      await pumpRouter(tester);
      await go(tester, AppRoutes.presets);

      final page = tester.widget<PresetsPage>(find.byType(PresetsPage));
      page.onOpenGlossaries!();
      await tester.pump();
      await tester.pump(_transition);

      expect(find.byType(GlossariesPage), findsOneWidget);
      expect(find.byType(AppShell), findsNothing);
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
        expect(launches, ['/']);

        await go(tester, AppRoutes.translate);
        expect(location(), AppRoutes.translate);
        expect(find.byType(TranslatePage), findsOneWidget);
        expect(launches, hasLength(1));
      });

      testWidgets('also applies to an explicit translate start', (
        tester,
      ) async {
        onboardingRouter(initialLocation: AppRoutes.translate);
        await pumpRouter(tester);

        expect(location(), AppRoutes.onboarding);
        expect(launches, [AppRoutes.translate]);
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

      const conversationFirst = AppSettings(
        tabOrder: [
          AppTab.conversation,
          AppTab.translate,
          AppTab.dictionary,
          AppTab.proofread,
        ],
      );

      /// A router whose launch redirect opens the first tab of
      /// [conversationFirst].
      GoRouter homeRouter({String? initialLocation}) {
        router.dispose();
        when(() => env.settingsCubit.state).thenReturn(conversationFirst);
        String? redirect(String location) =>
            homeRedirect(conversationFirst, location);
        return router = initialLocation == null
            ? createAppRouter(launchRedirect: redirect)
            : createAppRouter(
                launchRedirect: redirect,
                initialLocation: initialLocation,
              );
      }

      testWidgets('opens on the first tab of the order', (tester) async {
        homeRouter();
        await pumpRouter(tester);
        await tester.pump(_transition);

        expect(location(), AppRoutes.conversation);
        expect(find.byType(ConversationPage), findsOneWidget);
        // The tab shows first in the bar.
        final bar = tester.widget<NavigationBar>(find.byType(NavigationBar));
        expect(bar.selectedIndex, 0);
      });

      testWidgets('opens the root on the first tab of the order', (
        tester,
      ) async {
        homeRouter(initialLocation: '/');
        await pumpRouter(tester);
        await tester.pump(_transition);

        expect(location(), AppRoutes.conversation);
      });

      testWidgets('keeps an explicit start at the translate tab', (
        tester,
      ) async {
        homeRouter(initialLocation: AppRoutes.translate);
        await pumpRouter(tester);
        await tester.pump(_transition);

        expect(location(), AppRoutes.translate);
        expect(find.byType(TranslatePage), findsOneWidget);
      });

      testWidgets('keeps the translate tab the platform starts at (the '
          "widget's Type button, a web reload)", (tester) async {
        // mozhi://translate, which MainActivity hands over as /translate.
        tester.platformDispatcher.defaultRouteNameTestValue =
            AppRoutes.translate;
        addTearDown(tester.platformDispatcher.clearDefaultRouteNameTestValue);
        homeRouter();
        await pumpRouter(tester);
        await tester.pump(_transition);

        expect(location(), AppRoutes.translate);
        expect(find.byType(TranslatePage), findsOneWidget);
      });

      testWidgets('opens a plain platform start on the first tab', (
        tester,
      ) async {
        tester.platformDispatcher.defaultRouteNameTestValue = '/';
        addTearDown(tester.platformDispatcher.clearDefaultRouteNameTestValue);
        homeRouter();
        await pumpRouter(tester);
        await tester.pump(_transition);

        expect(location(), AppRoutes.conversation);
      });

      testWidgets('the onboarding finishes on the first tab of the order', (
        tester,
      ) async {
        when(() => env.settingsCubit.state).thenReturn(
          const AppSettings(
            tabOrder: [
              AppTab.dictionary,
              AppTab.translate,
              AppTab.proofread,
              AppTab.conversation,
            ],
          ),
        );
        await pumpRouter(tester);
        await go(tester, AppRoutes.onboarding);

        expect(
          tester
              .widget<OnboardingPage>(find.byType(OnboardingPage))
              .finishLocation,
          AppRoutes.dictionary,
        );
      });

      testWidgets('the onboarding finishes on translate by default', (
        tester,
      ) async {
        await pumpRouter(tester);
        await go(tester, AppRoutes.onboarding);

        expect(
          tester
              .widget<OnboardingPage>(find.byType(OnboardingPage))
              .finishLocation,
          AppRoutes.translate,
        );
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

    Future<void> tapTab(WidgetTester tester, String label) async {
      await tester.tap(
        find.descendant(
          of: find.byType(NavigationBar),
          matching: find.text(label),
        ),
      );
      await tester.pump();
      await tester.pump(_transition);
    }

    testWidgets('switches tabs from the navigation bar', (tester) async {
      await pumpRouter(tester);

      await tapTab(tester, 'Dictionary');
      expect(location(), '/dictionary');
      expect(find.byType(DictionaryPage), findsOneWidget);

      await tapTab(tester, 'Proofread');
      expect(location(), '/proofread');
      expect(find.byType(ProofreadPage), findsOneWidget);

      await tapTab(tester, 'Conversation');
      expect(location(), '/conversation');
      expect(find.byType(ConversationPage), findsOneWidget);

      await tapTab(tester, 'Translate');
      expect(location(), '/translate');
      expect(find.byType(TranslatePage), findsOneWidget);
    });

    testWidgets("keeps each tab's location and resets it on re-tap", (
      tester,
    ) async {
      await pumpRouter(tester);
      await go(tester, '/dictionary?word=gato');

      await tapTab(tester, 'Translate');
      expect(location(), '/translate');

      await tapTab(tester, 'Dictionary');
      expect(location(), '/dictionary?word=gato');
      expect(
        tester.widget<DictionaryPage>(find.byType(DictionaryPage)).word,
        'gato',
      );

      await tapTab(tester, 'Dictionary');
      expect(location(), '/dictionary');
      expect(
        tester.widget<DictionaryPage>(find.byType(DictionaryPage)).word,
        isNull,
      );
    });

    Future<void> tapAction(WidgetTester tester, Key key) async {
      await tester.tap(find.byKey(key));
      await tester.pump();
      await tester.pump(_transition);
    }

    for (final (key, page) in [
      (TopLevelActions.historyKey, HistoryPage),
      (TopLevelActions.settingsKey, SettingsPage),
    ]) {
      testWidgets('the app bar opens $page above the tabs and back returns', (
        tester,
      ) async {
        await pumpRouter(tester);
        await go(tester, '/proofread');

        await tapAction(tester, key);
        expect(find.byType(page), findsOneWidget);
        expect(find.byType(AppShell, skipOffstage: false), findsOneWidget);
        expect(find.byType(NavigationBar).hitTestable(), findsNothing);
        // The app bar's own back arrow (there is a page below).
        expect(find.byKey(const Key('top_level_back')), findsNothing);
        expect(find.byType(BackButton), findsOneWidget);

        await tester.tap(find.byType(BackButton));
        await tester.pump();
        await tester.pump(_transition);
        expect(find.byType(page), findsNothing);
        expect(location(), '/proofread');
        expect(find.byType(ProofreadPage), findsOneWidget);
      });
    }

    testWidgets('settings pages pushed from a tab go back to it', (
      tester,
    ) async {
      await pumpRouter(tester);
      await go(tester, '/conversation');

      unawaited(router.push<void>(AppRoutes.voiceSettings));
      await tester.pump();
      await tester.pump(_transition);
      expect(find.byType(VoiceInputSettingsPage), findsOneWidget);

      router.pop();
      await tester.pump();
      await tester.pump(_transition);
      expect(location(), '/conversation');
      expect(find.byType(ConversationPage), findsOneWidget);
    });

    for (final (path, page) in [
      (AppRoutes.history, HistoryPage),
      (AppRoutes.settings, SettingsPage),
    ]) {
      testWidgets('$path opened on its own goes back to the translate tab', (
        tester,
      ) async {
        await pumpRouter(tester);
        await go(tester, path);
        expect(find.byType(page), findsOneWidget);
        expect(find.byType(AppShell), findsNothing);

        await tester.tap(find.byKey(const Key('top_level_back')));
        await tester.pump();
        await tester.pump(_transition);
        expect(location(), AppRoutes.translate);
        expect(find.byType(TranslatePage), findsOneWidget);
      });

      testWidgets('system back on $path opened on its own goes to translate', (
        tester,
      ) async {
        await pumpRouter(tester);
        await go(tester, path);

        final handled = await tester.binding.handlePopRoute();
        await tester.pump();
        await tester.pump(_transition);
        expect(handled, isTrue);
        expect(location(), AppRoutes.translate);
      });
    }

    testWidgets('a settings sub-page opened on its own stacks on Settings', (
      tester,
    ) async {
      await pumpRouter(tester);
      await go(tester, AppRoutes.about);

      router.pop();
      await tester.pump();
      await tester.pump(_transition);
      expect(location(), AppRoutes.settings);
      expect(find.byType(SettingsPage), findsOneWidget);
    });

    testWidgets('a page pushed right after going to a tab sits above it', (
      tester,
    ) async {
      // How the onboarding opens the AI provider settings.
      await pumpRouter(tester);
      await go(tester, AppRoutes.onboarding);

      router.go(AppRoutes.translate);
      unawaited(router.push<void>(AppRoutes.providers));
      await tester.pump();
      await tester.pump(_transition);
      expect(find.byType(ProvidersPage), findsOneWidget);
      expect(find.byType(AppShell, skipOffstage: false), findsOneWidget);

      router.pop();
      await tester.pump();
      await tester.pump(_transition);
      expect(location(), AppRoutes.translate);
      expect(find.byType(TranslatePage), findsOneWidget);
    });

    testWidgets('face-to-face mode covers the tabs and back leaves it', (
      tester,
    ) async {
      await pumpRouter(tester);
      await go(tester, AppRoutes.conversation);

      await tester.tap(find.byKey(const Key('conversation_layout_toggle')));
      await tester.pump();
      await tester.pump(_transition);
      expect(
        find.byKey(const Key('conversation_face_to_face_layout')),
        findsOneWidget,
      );
      expect(find.byType(NavigationBar).hitTestable(), findsNothing);

      final handled = await tester.binding.handlePopRoute();
      await tester.pump();
      await tester.pump(_transition);
      expect(handled, isTrue);
      expect(
        find.byKey(const Key('conversation_face_to_face_layout')),
        findsNothing,
      );
      expect(find.byType(NavigationBar).hitTestable(), findsOneWidget);
      expect(location(), AppRoutes.conversation);
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
