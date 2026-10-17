import 'dart:async';

import 'package:bloc_test/bloc_test.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:go_router/go_router.dart';
import 'package:http/http.dart' as http;
import 'package:http/testing.dart';
import 'package:material_ui/material_ui.dart';
import 'package:mocktail/mocktail.dart';
import 'package:mozhi/l10n/l10n.dart';
import 'package:mozhi/settings/view/widgets/link_launcher.dart';
import 'package:mozhi/translate/cubit/translate_cubit.dart';
import 'package:mozhi/usage/usage.dart';
import 'package:mozhi/web_translate/web_translate.dart';
import 'package:mozhi/web_translate/widgets/web_reader.dart';
import 'package:share_plus/share_plus.dart';
import 'package:translation_repository/translation_repository.dart';

import '../helpers/helpers.dart';

class _MockUsageTracker extends Mock implements UsageTracker;

Future<ReadablePage> inlineExtract(FetchedWebPage page) async =>
    extractFetchedPage(page);

WebTranslatePage page({
  String? initialUrl,
  bool autoLoad = true,
  http.Client? client,
  bool isWeb = false,
}) => WebTranslatePage(
  initialUrl: initialUrl,
  autoLoad: autoLoad,
  fetcher: WebPageFetcher(
    isWeb: false,
    client: client ?? htmlClient(samplePageHtml),
  ),
  extract: inlineExtract,
  isWeb: isWeb,
);

void main() {
  late MockTranslateCubit translateCubit;
  late FakeTranslationRepository repository;

  setUp(() {
    translateCubit = MockTranslateCubit();
    when(() => translateCubit.state).thenReturn(translateState());
    repository = FakeTranslationRepository();
  });

  Future<void> pumpPage(
    WidgetTester tester,
    Widget child, {
    Size size = const Size(400, 900),
    UsageTracker? usageTracker,
  }) => tester.pumpWebTranslate(
    child,
    translateCubit: translateCubit,
    repository: repository,
    usageTracker: usageTracker,
    size: size,
  );

  Future<void> loadUrl(WidgetTester tester, String url) async {
    await tester.enterText(
      find.byKey(const Key('web_translate_url_field')),
      url,
    );
    await tester.tap(find.byKey(const Key('web_translate_go_button')));
    await tester.pumpAndSettle();
  }

  group('WebTranslatePage', () {
    testWidgets('shows the empty state and the controls', (tester) async {
      await pumpPage(tester, page());
      final l10n = lookupAppLocalizations(const Locale('en'));
      expect(find.text(l10n.webTranslateTitle), findsOneWidget);
      expect(find.text(l10n.webTranslateEmptyTitle), findsOneWidget);
      expect(find.byKey(const Key('web_translate_url_field')), findsOneWidget);
      expect(
        find.byKey(const Key('translate_engine_selector')),
        findsOneWidget,
      );
      expect(find.byKey(const Key('translate_target_button')), findsOneWidget);
      expect(find.byKey(const Key('web_translate_web_notice')), findsNothing);
      expect(find.byKey(const Key('web_translate_copy_button')), findsNothing);
    });

    testWidgets('explains the CORS limits on the web', (tester) async {
      await pumpPage(tester, page(isWeb: true));
      expect(find.byKey(const Key('web_translate_web_notice')), findsOneWidget);
    });

    testWidgets('loads and translates a page', (tester) async {
      await pumpPage(tester, page());
      await loadUrl(tester, 'example.com/sample');

      expect(find.text('SAMPLE PAGE'), findsOneWidget);
      expect(
        find.text(
          'FIRST PARAGRAPH OF THE SAMPLE PAGE, LONG ENOUGH TO BE CONTENT.',
        ),
        findsOneWidget,
      );
      expect(find.text('APPLES'), findsOneWidget);
      expect(find.text('1.'), findsOneWidget);
      expect(find.text('let x = 1;'), findsOneWidget);
      expect(find.text('Translated with Google'), findsOneWidget);
      expect(find.text('example.com'), findsOneWidget);
      // The field shows the normalised address.
      expect(find.text('https://example.com/sample'), findsOneWidget);
      expect(repository.requests.single.target, spanish);
    });

    testWidgets('switches between translation and original', (tester) async {
      await pumpPage(tester, page());
      await loadUrl(tester, 'example.com/sample');
      expect(find.text('Side by side'), findsNothing);

      await tester.tap(find.text('Original'));
      await tester.pumpAndSettle();
      expect(find.text('Sample page'), findsOneWidget);
      expect(find.text('Apples'), findsOneWidget);
      expect(find.text('APPLES'), findsNothing);
    });

    testWidgets('offers side by side on wide screens', (tester) async {
      await pumpPage(tester, page(), size: const Size(1300, 900));
      await loadUrl(tester, 'example.com/sample');
      await tester.tap(find.text('Side by side'));
      await tester.pumpAndSettle();
      expect(find.text('Apples'), findsOneWidget);
      expect(find.text('APPLES'), findsOneWidget);
      expect(find.text('Sample page'), findsOneWidget);
      expect(find.text('SAMPLE PAGE'), findsOneWidget);
    });

    testWidgets('loads the initial address automatically', (tester) async {
      await pumpPage(tester, page(initialUrl: 'https://example.com/sample'));
      await tester.pumpAndSettle();
      expect(find.text('SAMPLE PAGE'), findsOneWidget);
    });

    testWidgets('only fills in the initial address without autoLoad', (
      tester,
    ) async {
      await pumpPage(
        tester,
        page(initialUrl: 'https://example.com/sample', autoLoad: false),
      );
      await tester.pumpAndSettle();
      expect(find.text('https://example.com/sample'), findsOneWidget);
      expect(find.text('SAMPLE PAGE'), findsNothing);
      expect(repository.requests, isEmpty);

      await tester.tap(find.byKey(const Key('web_translate_go_button')));
      await tester.pumpAndSettle();
      expect(find.text('SAMPLE PAGE'), findsOneWidget);
    });

    testWidgets("counts AI requests with the app's usage tracker", (
      tester,
    ) async {
      const claude = TranslationEngine(
        id: 'ai:claude',
        kind: EngineKind.ai,
        name: 'Claude',
        providerId: 'claude',
      );
      when(() => translateCubit.state)
          .thenReturn(translateState(engine: claude));
      final tracker = _MockUsageTracker();
      when(
        () => tracker.recordText(
          any(),
          input: any(named: 'input'),
          output: any(named: 'output'),
        ),
      ).thenAnswer((_) async => const UsageStats(requests: 1));
      await pumpPage(tester, page(), usageTracker: tracker);
      await loadUrl(tester, 'example.com/sample');

      expect(find.text('SAMPLE PAGE'), findsOneWidget);
      final request = repository.requests.single;
      verify(
        () => tracker.recordText(
          'claude',
          input: request.text,
          output: request.text.toUpperCase(),
        ),
      ).called(1);
    });

    testWidgets(
      'counts AI requests of an address that was only filled in (a link)',
      (tester) async {
        const claude = TranslationEngine(
          id: 'ai:claude',
          kind: EngineKind.ai,
          name: 'Claude',
          providerId: 'claude',
        );
        when(() => translateCubit.state)
            .thenReturn(translateState(engine: claude));
        final tracker = _MockUsageTracker();
        when(
          () => tracker.recordText(
            any(),
            input: any(named: 'input'),
            output: any(named: 'output'),
          ),
        ).thenAnswer((_) async => const UsageStats(requests: 1));
        await pumpPage(
          tester,
          page(initialUrl: 'https://example.com/sample', autoLoad: false),
          usageTracker: tracker,
        );
        await tester.pumpAndSettle();
        expect(repository.requests, isEmpty);

        await tester.tap(find.byKey(const Key('web_translate_go_button')));
        await tester.pumpAndSettle();

        expect(find.text('SAMPLE PAGE'), findsOneWidget);
        final request = repository.requests.single;
        verify(
          () => tracker.recordText(
            'claude',
            input: request.text,
            output: request.text.toUpperCase(),
          ),
        ).called(1);
      },
    );

    testWidgets('flags invalid addresses', (tester) async {
      await pumpPage(tester, page());
      await loadUrl(tester, 'not an address');
      expect(
        find.text('Enter a valid web address (http or https)'),
        findsOneWidget,
      );
      await tester.enterText(
        find.byKey(const Key('web_translate_url_field')),
        'example.com',
      );
      await tester.pump();
      expect(
        find.text('Enter a valid web address (http or https)'),
        findsNothing,
      );
    });

    testWidgets('pastes an address and loads it', (tester) async {
      FakeClipboard(tester, pasteText: ' example.com/sample ');
      await pumpPage(tester, page());
      await tester.tap(find.byKey(const Key('web_translate_paste_button')));
      await tester.pumpAndSettle();
      expect(find.text('SAMPLE PAGE'), findsOneWidget);
    });

    testWidgets('ignores an empty clipboard', (tester) async {
      FakeClipboard(tester);
      await pumpPage(tester, page());
      await tester.tap(find.byKey(const Key('web_translate_paste_button')));
      await tester.pumpAndSettle();
      expect(find.text('Read any web page in your language'), findsOneWidget);
    });

    testWidgets('clears the address', (tester) async {
      await pumpPage(tester, page());
      await tester.enterText(
        find.byKey(const Key('web_translate_url_field')),
        'example.com',
      );
      await tester.pump();
      await tester.tap(find.byKey(const Key('web_translate_clear_button')));
      await tester.pump();
      expect(find.text('example.com'), findsNothing);
      expect(
        find.byKey(const Key('web_translate_paste_button')),
        findsOneWidget,
      );
    });

    testWidgets('shows download errors and retries', (tester) async {
      var fail = true;
      await pumpPage(
        tester,
        page(
          client: MockClient(
            (request) async => fail
                ? http.Response('gone', 404)
                : http.Response(samplePageHtml, 200),
          ),
        ),
      );
      await loadUrl(tester, 'example.com/sample');
      expect(
        find.text('The website answered with an error (404).'),
        findsOneWidget,
      );
      fail = false;
      await tester.tap(find.byKey(const Key('web_translate_retry_button')));
      await tester.pumpAndSettle();
      expect(find.text('SAMPLE PAGE'), findsOneWidget);
    });

    testWidgets('shows the original when no engine is available', (
      tester,
    ) async {
      when(() => translateCubit.state).thenReturn(translateState(engine: null));
      await pumpPage(tester, page());
      await loadUrl(tester, 'example.com/sample');
      expect(find.byKey(const Key('web_translate_no_engine')), findsOneWidget);
      expect(find.text('Sample page'), findsOneWidget);
      expect(find.text('Apples'), findsOneWidget);
      expect(repository.requests, isEmpty);
    });

    testWidgets('re-translates when the target language changes', (
      tester,
    ) async {
      final states = StreamController<TranslateState>();
      addTearDown(states.close);
      whenListen(translateCubit, states.stream, initialState: translateState());
      await pumpPage(tester, page());
      await loadUrl(tester, 'example.com/sample');
      expect(repository.requests.single.target, spanish);

      states.add(translateState(target: arabic));
      await tester.pumpAndSettle();
      expect(repository.requests.last.target, arabic);
      // Arabic is laid out right to left.
      final directionality = tester.widget<Directionality>(
        find
            .ancestor(
              of: find.text('APPLES'),
              matching: find.byType(Directionality),
            )
            .first,
      );
      expect(directionality.textDirection, TextDirection.rtl);
    });

    testWidgets('translates once engines become available', (tester) async {
      final states = StreamController<TranslateState>();
      addTearDown(states.close);
      whenListen(
        translateCubit,
        states.stream,
        initialState: translateState(engine: null),
      );
      await pumpPage(tester, page());
      await loadUrl(tester, 'example.com/sample');
      expect(repository.requests, isEmpty);

      states.add(translateState());
      await tester.pumpAndSettle();
      expect(find.text('SAMPLE PAGE'), findsOneWidget);
    });

    testWidgets('copies, shares and opens the page', (tester) async {
      final clipboard = FakeClipboard(tester);
      ShareParams? shared;
      WebTranslateShare.share = (params) async => shared = params;
      addTearDown(() => WebTranslateShare.share = SharePlus.instance.share);
      final opened = <Uri>[];
      final previousLauncher = LinkLauncher.launcher;
      LinkLauncher.launcher = (uri) async {
        opened.add(uri);
        return true;
      };
      addTearDown(() => LinkLauncher.launcher = previousLauncher);

      await pumpPage(tester, page());
      await loadUrl(tester, 'example.com/sample');

      await tester.tap(find.byKey(const Key('web_translate_copy_button')));
      await tester.pumpAndSettle();
      expect(clipboard.copied, startsWith('SAMPLE PAGE\n\nFIRST PARAGRAPH'));
      expect(find.text('Copied to clipboard'), findsOneWidget);

      await tester.tap(find.byKey(const Key('web_translate_share_button')));
      await tester.pump();
      expect(shared!.text, startsWith('SAMPLE PAGE'));
      expect(shared!.text, endsWith('https://example.com/sample'));
      expect(shared!.subject, 'SAMPLE PAGE');

      await tester.tap(find.byKey(const Key('web_translate_open_button')));
      await tester.tap(find.byKey(const Key('web_translate_source_link')));
      await tester.pump();
      expect(opened, [
        Uri.parse('https://example.com/sample'),
        Uri.parse('https://example.com/sample'),
      ]);

      // In original mode the original text is copied.
      await tester.tap(find.text('Original'));
      await tester.pumpAndSettle();
      await tester.tap(find.byKey(const Key('web_translate_copy_button')));
      await tester.pumpAndSettle();
      expect(clipboard.copied, startsWith('Sample page\n\nFirst paragraph'));
      await tester.tap(find.byKey(const Key('web_translate_share_button')));
      await tester.pump();
      expect(shared!.subject, 'Sample page');
      expect(shared!.text, startsWith('Sample page\n\nFirst paragraph'));
    });

    testWidgets('loads when the keyboard action is pressed', (tester) async {
      await pumpPage(tester, page());
      await tester.enterText(
        find.byKey(const Key('web_translate_url_field')),
        'example.com/sample',
      );
      await tester.testTextInput.receiveAction(TextInputAction.go);
      await tester.pumpAndSettle();
      expect(find.text('SAMPLE PAGE'), findsOneWidget);
    });

    testWidgets('ignores selection changes while loading', (tester) async {
      final response = Completer<http.Response>();
      final states = StreamController<TranslateState>();
      addTearDown(states.close);
      whenListen(translateCubit, states.stream, initialState: translateState());
      await pumpPage(
        tester,
        page(client: MockClient((request) => response.future)),
      );
      await tester.enterText(
        find.byKey(const Key('web_translate_url_field')),
        'example.com/sample',
      );
      await tester.tap(find.byKey(const Key('web_translate_go_button')));
      await tester.pump();

      // Changed while loading: ignored.
      states.add(translateState(target: arabic));
      await tester.pump();
      response.complete(http.Response(samplePageHtml, 200));
      await tester.pumpAndSettle();
      expect(repository.requests.single.target, spanish);

      // Back to the selection the page was translated with: nothing to do.
      states.add(translateState());
      await tester.pumpAndSettle();
      expect(repository.requests, hasLength(1));
    });
  });

  group('WebTranslateButton', () {
    testWidgets('opens the web translator route', (tester) async {
      final router = GoRouter(
        routes: [
          GoRoute(
            path: '/',
            builder: (context, state) => Scaffold(
              appBar: AppBar(
                // A non-const instance (covers the constructor).
                // ignore: prefer_const_constructors, prefer_const_literals_to_create_immutables
                actions: [WebTranslateButton(url: 'example.com')],
              ),
            ),
          ),
          GoRoute(
            path: WebTranslateRoute.path,
            builder: (context, state) {
              final params = state.uri.queryParameters;
              return Text('web ${params[WebTranslateRoute.urlParameter]}');
            },
          ),
        ],
      );
      addTearDown(router.dispose);
      await tester.pumpWidget(
        MaterialApp.router(
          routerConfig: router,
          localizationsDelegates: appLocalizationsDelegates,
          supportedLocales: AppLocalizations.supportedLocales,
        ),
      );
      await tester.tap(find.byKey(const Key('web_translate_open_page_button')));
      await tester.pumpAndSettle();
      expect(find.text('web example.com'), findsOneWidget);
    });

    test('route locations', () {
      expect(WebTranslateRoute.location(), '/translate/web');
      expect(WebTranslateRoute.location(url: '  '), '/translate/web');
      expect(
        WebTranslateRoute.location(url: 'https://a.b/c?d=1'),
        '/translate/web?url=https%3A%2F%2Fa.b%2Fc%3Fd%3D1',
      );
    });
  });

  test('webTranslateSelectionOf mirrors the translate state', () {
    expect(webTranslateSelectionOf(translateState(engine: null)), isNull);
    expect(webTranslateSelectionOf(translateState()), googleToSpanish);
  });
}
