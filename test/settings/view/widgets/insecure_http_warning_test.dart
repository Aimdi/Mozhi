import 'package:flutter_test/flutter_test.dart';
import 'package:material_ui/material_ui.dart';
import 'package:mozhi/settings/view/widgets/insecure_http_warning.dart';

import '../../../helpers/pump_app.dart';

void main() {
  group('isInsecureHttp', () {
    test('is true for plain http to a public host', () {
      expect(isInsecureHttp(Uri.parse('http://mozhi.example.com')), isTrue);
      expect(isInsecureHttp(Uri.parse('HTTP://8.8.8.8:3000')), isTrue);
      expect(isInsecureHttp(Uri.parse('http://[2001:db8::1]')), isTrue);
    });

    test('is false for https, local and LAN hosts', () {
      expect(isInsecureHttp(Uri.parse('https://mozhi.example.com')), isFalse);
      expect(isInsecureHttp(Uri.parse('http://localhost:3000')), isFalse);
      expect(isInsecureHttp(Uri.parse('http://127.0.0.1')), isFalse);
      expect(isInsecureHttp(Uri.parse('http://192.168.0.2')), isFalse);
      expect(isInsecureHttp(Uri.parse('http://172.16.4.1')), isFalse);
      expect(isInsecureHttp(Uri.parse('http://box.local')), isFalse);
      expect(isInsecureHttp(Uri.parse('http://[::1]:3000')), isFalse);
      expect(isInsecureHttp(Uri.parse('http://mozhibox')), isFalse);
    });

    test('is false without a usable URL', () {
      expect(isInsecureHttp(null), isFalse);
      expect(isInsecureHttp(Uri.parse('http:relative')), isFalse);
      expect(isInsecureHttp(Uri.parse('/path')), isFalse);
    });
  });

  group('InsecureHttpWarning', () {
    testWidgets('shows title and text as a live region on errorContainer', (
      tester,
    ) async {
      await tester.pumpApp(
        const Scaffold(
          body: InsecureHttpWarning(title: 'Title', text: 'Body'),
        ),
      );
      expect(find.text('Title'), findsOneWidget);
      expect(find.text('Body'), findsOneWidget);
      expect(find.byIcon(Icons.no_encryption_outlined), findsOneWidget);
      expect(
        tester.getSemantics(find.text('Title')),
        isSemantics(isLiveRegion: true),
      );
      final colors = Theme.of(tester.element(find.text('Body'))).colorScheme;
      expect(
        tester.widget<Card>(find.byType(Card)).color,
        colors.errorContainer,
      );
    });

    testWidgets('renders in dark mode', (tester) async {
      await tester.pumpApp(
        const Scaffold(
          body: InsecureHttpWarning(title: 'Title', text: 'Body'),
        ),
        theme: ThemeData(brightness: Brightness.dark),
      );
      expect(tester.takeException(), isNull);
      expect(find.text('Title'), findsOneWidget);
    });
  });
}
