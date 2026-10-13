import 'package:flutter_test/flutter_test.dart';
import 'package:material_ui/material_ui.dart';
import 'package:mozhi/onboarding/onboarding.dart';

import '../helpers.dart';

void main() {
  group('WelcomeStep', () {
    testWidgets('explains Mozhi and privacy', (tester) async {
      tester.setScreenSize(const Size(400, 1400));
      await tester.pumpOnboarding(const WelcomeStep());

      expect(find.text('Welcome to Mozhi'), findsOneWidget);
      expect(find.text('Many engines, one app'), findsOneWidget);
      expect(find.textContaining('Google, DeepL, Yandex'), findsOneWidget);
      expect(find.text('Optional AI translation'), findsOneWidget);
      expect(find.text('Private by design'), findsOneWidget);
      expect(
        find.textContaining('only sent to the Mozhi instance'),
        findsOneWidget,
      );
    });

    testWidgets('title is a semantic header', (tester) async {
      final handle = tester.ensureSemantics();
      await tester.pumpOnboarding(const WelcomeStep());
      expect(
        tester.getSemantics(find.text('Welcome to Mozhi')),
        matchesSemantics(label: 'Welcome to Mozhi', isHeader: true),
      );
      handle.dispose();
    });

    testWidgets('centres content on wide screens', (tester) async {
      tester.setScreenSize(const Size(1400, 900));
      await tester.pumpOnboarding(const WelcomeStep());
      final rect = tester.getRect(find.text('Welcome to Mozhi'));
      expect(rect.left, greaterThanOrEqualTo((1400 - 640) / 2 - 1));
      expect(tester.takeException(), isNull);
    });
  });
}
