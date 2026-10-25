import 'dart:async';

import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:go_router/go_router.dart';
import 'package:material_ui/material_ui.dart';
import 'package:mozhi/app/router.dart';
import 'package:mozhi/l10n/l10n.dart';
import 'package:mozhi/screen_translate/screen_translate.dart';

import '../app/mocks.dart';

// The router in the screen-translate window shows nothing but its page, and
// hands other locations to the main window; the main window never shows it.
void main() {
  const channel = MethodChannel(ScreenTranslateHost.channelName);
  late List<MethodCall> calls;
  late GoRouter router;
  late ScreenTranslateHost previousHost;

  setUpAll(registerAppFallbacks);

  setUp(() {
    previousHost = ScreenTranslateHost.instance;
    calls = [];
    TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger
        .setMockMethodCallHandler(channel, (call) {
          calls.add(call);
          // The consent is still open: `screenshot` never answers.
          return call.method == 'screenshot'
              ? Completer<Object?>().future
              : Future.value();
        });
  });

  tearDown(() {
    ScreenTranslateHost.instance = previousHost;
    TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger
        .setMockMethodCallHandler(channel, null);
  });

  Future<void> pump(WidgetTester tester, GoRouter router) async {
    addTearDown(router.dispose);
    final env = TestEnvironment();
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

  String location() =>
      router.routerDelegate.currentConfiguration.uri.toString();

  testWidgets('the window shows only its page', (tester) async {
    final host = ScreenTranslateHost(
      initialRoute: () => ScreenTranslateHost.location,
    );
    // The window's page asks the app's host.
    ScreenTranslateHost.instance = host;
    router = createAppRouter(
      screenTranslateHost: host,
      quickTranslateWindow: false,
      launchRedirect: (_) => AppRoutes.onboarding,
    );
    await pump(tester, router);
    await tester.pump();

    expect(location(), AppRoutes.screenTranslate);
    expect(find.byType(ScreenTranslatePage), findsOneWidget);
    expect(calls.map((c) => c.method), ['screenshot']);

    router.go(AppRoutes.offline);
    await tester.pump();
    await tester.pump();
    expect(location(), AppRoutes.screenTranslate);
    expect(calls.last.method, 'openInApp');
    expect(calls.last.arguments, {'location': AppRoutes.offline});
    // Asked once, whatever the router rebuilds.
    expect(calls.where((c) => c.method == 'screenshot'), hasLength(1));
  });

  testWidgets('the main window never shows it', (tester) async {
    router = createAppRouter(
      screenTranslateHost: ScreenTranslateHost(initialRoute: () => '/'),
      quickTranslateWindow: false,
    );
    await pump(tester, router);
    router.go(AppRoutes.screenTranslate);
    await tester.pump();
    await tester.pump(const Duration(seconds: 1));

    expect(location(), AppRoutes.translate);
    expect(find.byType(ScreenTranslatePage), findsNothing);
    expect(calls, isEmpty);
  });

  testWidgets('the quick translate window never shows it either', (
    tester,
  ) async {
    router = createAppRouter(
      screenTranslateHost: ScreenTranslateHost(
        initialRoute: () => ScreenTranslateHost.location,
      ),
      quickTranslateWindow: true,
    );
    await pump(tester, router);
    router.go(AppRoutes.screenTranslate);
    await tester.pump();

    expect(location(), AppRoutes.quickTranslate);
    expect(find.byType(ScreenTranslatePage), findsNothing);
  });

  test('the location is the host location', () {
    expect(AppRoutes.screenTranslate, ScreenTranslateHost.location);
  });
}
