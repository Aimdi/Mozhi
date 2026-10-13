import 'package:flutter_test/flutter_test.dart';
import 'package:material_ui/material_ui.dart';
import 'package:mozhi/onboarding/onboarding.dart';

import '../helpers.dart';

void main() {
  group('OnboardingNavBar', () {
    Future<List<String>> pump(WidgetTester tester, OnboardingStep step) async {
      final calls = <String>[];
      await tester.pumpOnboarding(
        Align(
          alignment: Alignment.bottomCenter,
          child: OnboardingNavBar(
            step: step,
            onBack: () => calls.add('back'),
            onNext: () => calls.add('next'),
            onFinish: () => calls.add('finish'),
          ),
        ),
      );
      return calls;
    }

    testWidgets('first step has no Back', (tester) async {
      final calls = await pump(tester, OnboardingStep.welcome);
      expect(find.text('Back'), findsNothing);
      await tester.tap(find.text('Next'));
      expect(calls, ['next']);
    });

    testWidgets('middle steps go back and forward', (tester) async {
      final calls = await pump(tester, OnboardingStep.ai);
      await tester.tap(find.text('Back'));
      await tester.tap(find.text('Next'));
      expect(calls, ['back', 'next']);
    });

    testWidgets('last step finishes', (tester) async {
      final calls = await pump(tester, OnboardingStep.done);
      expect(find.text('Next'), findsNothing);
      await tester.tap(find.text('Start translating'));
      expect(calls, ['finish']);
    });

    testWidgets('buttons are at least 48dp tall', (tester) async {
      await pump(tester, OnboardingStep.service);
      for (final label in ['Back', 'Next']) {
        final size = tester.getSize(
          find.ancestor(
            of: find.text(label),
            matching: find.byWidgetPredicate((w) => w is ButtonStyleButton),
          ),
        );
        expect(size.height, greaterThanOrEqualTo(48), reason: label);
      }
    });
  });

  group('OnboardingProgressDots', () {
    testWidgets('announces the step and highlights the current dot', (
      tester,
    ) async {
      final handle = tester.ensureSemantics();
      await tester.pumpOnboarding(
        const Center(child: OnboardingProgressDots(count: 4, current: 1)),
      );
      expect(find.bySemanticsLabel('Step 2 of 4'), findsOneWidget);
      expect(
        tester.getSize(find.byKey(const ValueKey('onboarding-dot-1'))).width,
        greaterThan(
          tester.getSize(find.byKey(const ValueKey('onboarding-dot-2'))).width,
        ),
      );
      handle.dispose();
    });
  });
}
