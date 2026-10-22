import 'package:flutter/foundation.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:go_router/go_router.dart';
import 'package:material_ui/material_ui.dart';
import 'package:mozhi/app/router.dart';
import 'package:mozhi/l10n/l10n.dart';
import 'package:mozhi/pairing/cubit/pairing_send_cubit.dart';
import 'package:mozhi/pairing/pairing_routes.dart';
import 'package:mozhi/pairing/protocol/pairing_code.dart';
import 'package:mozhi/pairing/view/pairing_entries.dart';
import 'package:mozhi/pairing/view/pairing_pages.dart';
import 'package:mozhi/platform/lan_address.dart';

import '../helpers/helpers.dart';

void main() {
  final code = PairingCode(
    address: const [192, 168, 1, 20],
    port: 41234,
    secret: List.filled(8, 7),
  );

  group('PairingRoutes', () {
    test('builds the send location', () {
      expect(PairingRoutes.sendLocation(), '/pairing/send');
      expect(PairingRoutes.sendLocation(code: ''), '/pairing/send');
      expect(
        PairingRoutes.sendLocation(code: 'AB', packs: true),
        '/pairing/send?code=AB&what=packs',
      );
      expect(AppRoutes.pairing, '/pairing');
      expect(AppRoutes.pairingReceive, '/pairing/receive');
      expect(AppRoutes.pairingSend, '/pairing/send');
    });

    test('a mozhi://pair link opens the send screen with its code', () {
      final link = Uri.parse(code.link);
      final location = appRedirect(link, null);
      expect(location, '/pair?code=${link.queryParameters['code']}');
      expect(
        appRedirect(Uri.parse(location!), null),
        '/pairing/send?code=${link.queryParameters['code']}',
      );
    });

    test('pairingSendPageFor reads the code and the purpose', () {
      final page = pairingSendPageFor(
        Uri.parse('/pairing/send?code=AB&what=packs'),
      ) as PairingSendPage;
      expect(page.initialCode, 'AB');
      expect(page.purpose, PairingSendPurpose.packs);
      final plain =
          pairingSendPageFor(Uri.parse('/pairing/send')) as PairingSendPage;
      expect(plain.initialCode, isNull);
      expect(plain.purpose, PairingSendPurpose.everything);
    });
  });

  group('the app router', () {
    late GoRouter router;

    tearDown(() => router.dispose());

    Future<void> pumpAt(WidgetTester tester, String location) async {
      router = createAppRouter(initialLocation: location);
      await tester.pumpWidget(
        MaterialApp.router(
          routerConfig: router,
          localizationsDelegates: appLocalizationsDelegates,
          supportedLocales: AppLocalizations.supportedLocales,
        ),
      );
      await tester.pumpAndSettle();
    }

    testWidgets('opens the send screen of a pairing link', (tester) async {
      // As the Android app hands mozhi://pair?code=… to the router.
      await pumpAt(tester, '/pair?${Uri.parse(code.link).query}');
      expect(find.byType(PairingSendPage), findsOneWidget);
      expect(find.text(code.link.split('=').last), findsOneWidget);
      expect(
        router.routerDelegate.currentConfiguration.uri.path,
        '/pairing/send',
      );
    });

    testWidgets('opens the receive screen and the overview', (tester) async {
      // No network: the receive screen says so, without listening.
      debugLanInterfaces = () async => const [];
      addTearDown(() => debugLanInterfaces = null);
      await pumpAt(tester, AppRoutes.pairing);
      expect(find.byType(PairingPage), findsOneWidget);
      router.go(AppRoutes.pairingReceive);
      await tester.pump();
      await tester.pump(const Duration(milliseconds: 600));
      expect(find.byType(PairingReceivePage), findsOneWidget);
      await tester.pump();
      expect(
        find.text('Connect to Wi-Fi or turn on a hotspot'),
        findsOneWidget,
      );
    });
  });

  group('entry points', () {
    late GoRouter router;
    late List<String> opened;

    setUp(() => opened = []);
    tearDown(() => router.dispose());

    Future<void> pump(WidgetTester tester, Widget child) async {
      router = GoRouter(
        routes: [
          GoRoute(
            path: '/',
            builder: (_, _) => Scaffold(body: ListView(children: [child])),
          ),
          GoRoute(
            path: '/pairing/:screen',
            builder: (_, state) {
              opened.add(state.uri.toString());
              return const Text('opened');
            },
          ),
        ],
      );
      await tester.pumpWidget(
        MaterialApp.router(
          routerConfig: router,
          localizationsDelegates: appLocalizationsDelegates,
          supportedLocales: AppLocalizations.supportedLocales,
        ),
      );
    }

    testWidgets('the settings section opens both screens', (tester) async {
      await pump(tester, const PairingSettingsSection());
      expect(find.text('Phone to phone'), findsOneWidget);
      await tester.tap(find.text('Receive on this phone'));
      await tester.pumpAndSettle();
      expect(opened, ['/pairing/receive']);
      router.pop();
      await tester.pumpAndSettle();
      await tester.tap(find.text('Send to another phone'));
      await tester.pumpAndSettle();
      expect(opened.last, '/pairing/send');
    });

    testWidgets('Share language packs opens the send screen', (tester) async {
      await pump(tester, const SharePacksEntry());
      await tester.tap(find.text('Share language packs'));
      await tester.pumpAndSettle();
      expect(opened, ['/pairing/send?what=packs']);
    });

    testWidgets('show nothing outside Android', (tester) async {
      debugDefaultTargetPlatformOverride = TargetPlatform.iOS;
      await pump(
        tester,
        const Column(children: [PairingSettingsSection(), SharePacksEntry()]),
      );
      expect(find.byType(ListTile), findsNothing);
      debugDefaultTargetPlatformOverride = null;
    });
  });

  group('PairingPage', () {
    testWidgets('the overview page is not available outside Android', (
      tester,
    ) async {
      debugDefaultTargetPlatformOverride = TargetPlatform.iOS;
      await tester.pumpApp(const PairingPage());
      expect(
        find.text('Phone to phone works in the Android app.'),
        findsOneWidget,
      );
      debugDefaultTargetPlatformOverride = null;
    });
  });
}
