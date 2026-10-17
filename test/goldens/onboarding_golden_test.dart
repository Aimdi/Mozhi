@Tags(['golden', 'skip_very_good_optimization'])
library;

import 'package:flutter_test/flutter_test.dart';
import 'package:material_ui/material_ui.dart';
import 'package:mocktail/mocktail.dart';
import 'package:mozhi/core/key_value_store.dart';
import 'package:mozhi/onboarding/onboarding.dart';

import '../onboarding/helpers.dart';
import 'helpers/golden_helpers.dart';

void main() {
  setUpAll(registerOnboardingFallbacks);

  goldenGroup('Onboarding', () {
    for (final brightness in [Brightness.light, Brightness.dark]) {
      testWidgets('privacy and languages steps on a phone '
          '(${brightness.name})', (tester) async {
        final repository = MockTranslationRepository();
        when(() => repository.pingInstance(any()))
            .thenAnswer((_) async => const Duration(milliseconds: 100));
        final settings = createSettings();
        addTearDown(settings.close);
        final offline = FakeOfflineTranslator();
        useGoldenDevice(tester, GoldenDevice.phone);
        await tester.pumpOnboarding(
          OnboardingPage(
            translator: offline,
            store: MemoryStore(),
            details: FakeModelDetails(offline),
          ),
          settings: settings,
          repository: repository,
          router: MockGoRouter(),
          scaffold: false,
          theme: goldenTheme(brightness),
        );
        await tester.pumpAndSettle();

        await tester.tap(find.text('Next'));
        await tester.pumpAndSettle();
        expect(find.byType(PrivacyStep), findsOneWidget);
        await expectScreenGolden('onboarding_privacy_phone_${brightness.name}');

        await tester.tap(find.text('Next'));
        await tester.pumpAndSettle();
        expect(find.byType(LanguagesStep), findsOneWidget);
        await expectScreenGolden(
          'onboarding_languages_phone_${brightness.name}',
        );
      });
    }
  });
}
