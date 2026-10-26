import 'package:flutter_test/flutter_test.dart';
import 'package:go_router/go_router.dart';
import 'package:material_ui/material_ui.dart';
import 'package:mocktail/mocktail.dart';
import 'package:mozhi/app/router.dart';
import 'package:mozhi/app/view/app_shell.dart';
import 'package:mozhi/l10n/l10n.dart';
import 'package:mozhi/live_captions/view/live_captions_page.dart';
import 'package:mozhi/live_captions/widgets/live_captions_widgets.dart';
import 'package:mozhi/transcribe/view/transcribe_page.dart';

import '../app/mocks.dart';

class _MockRouter extends Mock implements GoRouter;

void main() {
  setUpAll(() async {
    registerAppFallbacks();
    await DeferredFeatures.liveCaptions.load();
    await DeferredFeatures.transcribe.load();
  });

  test('live captions are a deferred page of their own', () {
    expect(AppRoutes.liveCaptions, '/transcribe/captions');
    expect(DeferredFeatures.all, contains(DeferredFeatures.liveCaptions));
  });

  group('the route', () {
    late TestEnvironment env;
    late GoRouter router;

    setUp(() {
      env = TestEnvironment();
      router = createAppRouter(launchRedirect: (_) => null);
    });

    tearDown(() => router.dispose());

    Future<void> go(WidgetTester tester, String location) async {
      tester.view
        ..physicalSize = const Size(400, 900)
        ..devicePixelRatio = 1;
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
      router.go(location);
      await tester.pump();
      await tester.pump(const Duration(seconds: 1));
    }

    testWidgets('opens live captions full screen', (tester) async {
      await go(tester, AppRoutes.liveCaptions);
      expect(
        router.routerDelegate.currentConfiguration.uri.toString(),
        AppRoutes.liveCaptions,
      );
      expect(find.byType(LiveCaptionsPage), findsOneWidget);
      expect(find.byType(AppShell), findsNothing);
      // Not Android 10+ (a test host): captions say they need it.
      expect(
        find.byKey(const Key('live_captions_unavailable_unsupported')),
        findsOneWidget,
      );
    });

    testWidgets('a deep link opens it too', (tester) async {
      final location = deepLinkLocation(
        Uri.parse('mozhi://transcribe/captions'),
      );
      expect(location, AppRoutes.liveCaptions);
      await go(tester, location!);
      expect(find.byType(LiveCaptionsPage), findsOneWidget);
    });

    testWidgets('Transcribe offers "Caption other apps" where they run', (
      tester,
    ) async {
      tester.view
        ..physicalSize = const Size(400, 900)
        ..devicePixelRatio = 1;
      addTearDown(tester.view.reset);
      await tester.pumpWidget(
        env.wrap(
          MaterialApp(
            localizationsDelegates: appLocalizationsDelegates,
            supportedLocales: AppLocalizations.supportedLocales,
            home: TranscribePage(captionsAvailable: () async => true),
          ),
        ),
      );
      await tester.pump();
      await tester.pump();
      expect(find.byKey(const Key('live_captions_entry')), findsOneWidget);
    });

    testWidgets('Transcribe offers it only where captions run', (tester) async {
      await go(tester, AppRoutes.transcribe);
      expect(find.byType(TranscribePage), findsOneWidget);
      expect(find.byKey(const Key('live_captions_entry')), findsNothing);
    });
  });

  group('LiveCaptionsEntryButton', () {
    Future<void> pump(
      WidgetTester tester, {
      required bool available,
      GoRouter? router,
    }) async {
      Widget button = LiveCaptionsEntryButton(available: () async => available);
      if (router != null) {
        button = InheritedGoRouter(goRouter: router, child: button);
      }
      await tester.pumpWidget(
        MaterialApp(
          localizationsDelegates: appLocalizationsDelegates,
          supportedLocales: AppLocalizations.supportedLocales,
          home: Scaffold(appBar: AppBar(actions: [button])),
        ),
      );
      await tester.pump();
    }

    late AppLocalizations l10n;

    setUpAll(() async {
      l10n = await AppLocalizations.delegate.load(const Locale('en'));
    });

    testWidgets('opens live captions where they run', (tester) async {
      final router = _MockRouter();
      when(() => router.push<void>(any())).thenAnswer((_) async {});
      await pump(tester, available: true, router: router);
      final button = tester.widget<IconButton>(
        find.byKey(const Key('live_captions_entry')),
      );
      expect(button.tooltip, contains(l10n.liveCaptionsEntry));
      await tester.tap(find.byKey(const Key('live_captions_entry')));
      verify(() => router.push<void>(AppRoutes.liveCaptions)).called(1);
    });

    testWidgets('is hidden elsewhere', (tester) async {
      await pump(tester, available: false);
      expect(find.byKey(const Key('live_captions_entry')), findsNothing);
    });

    testWidgets('asks the platform by default (not here)', (tester) async {
      await tester.pumpWidget(
        const MaterialApp(
          localizationsDelegates: appLocalizationsDelegates,
          home: Scaffold(body: LiveCaptionsEntryButton()),
        ),
      );
      await tester.pump();
      expect(find.byKey(const Key('live_captions_entry')), findsNothing);
    });
  });
}
