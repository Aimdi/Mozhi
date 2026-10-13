import 'package:flutter_test/flutter_test.dart';
import 'package:material_ui/material_ui.dart';
import 'package:mozhi/settings/view/about_page.dart';
import 'package:mozhi/settings/view/widgets/link_launcher.dart';
import 'package:package_info_plus/package_info_plus.dart';

import 'helpers.dart';

void main() {
  setUpAll(registerFallbacks);

  group('AboutPage', () {
    late List<Uri> opened;
    late Future<bool> Function(Uri) original;

    setUp(() {
      PackageInfo.setMockInitialValues(
        appName: 'Mozhi',
        packageName: 'app.mozhi',
        version: '1.2.3',
        buildNumber: '45',
        buildSignature: '',
      );
      opened = [];
      original = LinkLauncher.launcher;
      LinkLauncher.launcher = (uri) async {
        opened.add(uri);
        return true;
      };
    });

    tearDown(() => LinkLauncher.launcher = original);

    Future<void> pump(
      WidgetTester tester, {
      Size size = const Size(800, 1600),
      double textScale = 1,
    }) async {
      tester.setScreenSize(size);
      await tester.pumpView(const AboutPage(), textScale: textScale);
      await tester.pumpAndSettle();
    }

    testWidgets('shows name, version and description', (tester) async {
      await pump(tester);
      expect(find.text('Mozhi'), findsOneWidget);
      expect(find.text('Version 1.2.3 (45)'), findsOneWidget);
      expect(find.textContaining('fast, private translator'), findsOneWidget);
    });

    testWidgets('omits an empty build number', (tester) async {
      PackageInfo.setMockInitialValues(
        appName: 'Mozhi',
        packageName: 'app.mozhi',
        version: '2.0.0',
        buildNumber: '',
        buildSignature: '',
      );
      await pump(tester);
      expect(find.text('Version 2.0.0'), findsOneWidget);
    });

    testWidgets('states the privacy promises', (tester) async {
      await pump(tester);
      expect(find.text('No telemetry, analytics or ads.'), findsOneWidget);
      expect(find.text('Your history stays on this device.'), findsOneWidget);
      expect(
        find.text(
          'Text is sent only to the Mozhi instances and AI providers you '
          'choose.',
        ),
        findsOneWidget,
      );
    });

    testWidgets('opens the source code', (tester) async {
      await pump(tester);
      await tester.tap(find.text('Source code'));
      await tester.pump();
      expect(opened, [Uri.parse('https://github.com/Aimdi/Mozhi')]);
    });

    testWidgets('opens the Mozhi project', (tester) async {
      await pump(tester);
      await tester.tap(find.text('Mozhi project'));
      await tester.pump();
      expect(opened, [Uri.parse('https://codeberg.org/aryak/mozhi')]);
    });

    testWidgets('shows licenses', (tester) async {
      await pump(tester);
      await tester.tap(find.text('Open-source licenses'));
      await tester.pumpAndSettle();
      expect(find.byType(LicensePage), findsOneWidget);
    });

    testWidgets('fits 320dp with large text', (tester) async {
      await pump(tester, size: const Size(320, 640), textScale: 2);
      expect(tester.takeException(), isNull);
    });
  });
}
