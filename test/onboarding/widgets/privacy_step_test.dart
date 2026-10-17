import 'package:flutter_test/flutter_test.dart';
import 'package:material_ui/material_ui.dart';
import 'package:mocktail/mocktail.dart';
import 'package:mozhi/onboarding/onboarding.dart';
import 'package:translation_repository/translation_repository.dart';

import '../helpers.dart';

void main() {
  setUpAll(() => registerFallbackValue(PrivacyMode.online));

  group('PrivacyStep', () {
    testWidgets('offers the three modes, offline first by default', (
      tester,
    ) async {
      tester.setScreenSize(const Size(400, 1400));
      final onboarding = createOnboardingCubit();
      await tester.pumpOnboarding(const PrivacyStep(), onboarding: onboarding);

      expect(find.text('How private should translations be?'), findsOneWidget);
      expect(find.text('Offline only'), findsOneWidget);
      expect(find.text('Offline first (recommended)'), findsOneWidget);
      expect(find.text('Online'), findsOneWidget);
      final group = tester.widget<RadioGroup<PrivacyMode>>(
        find.byType(RadioGroup<PrivacyMode>),
      );
      expect(group.groupValue, PrivacyMode.offlineFirst);
      // Without a repository that can tell, the device is assumed to have
      // an on-device engine.
      expect(find.textContaining('no engine to translate with'), findsNothing);

      await tester.tap(find.byKey(const Key('onboarding_privacy_online')));
      verify(() => onboarding.setPrivacyMode(PrivacyMode.online)).called(1);
    });

    testWidgets('warns when the device cannot translate on its own', (
      tester,
    ) async {
      tester.setScreenSize(const Size(400, 1400));
      final repository = MockTranslationRepository();
      when(() => repository.hasOfflineEngine).thenReturn(false);
      await tester.pumpOnboarding(
        const PrivacyStep(),
        onboarding: createOnboardingCubit(),
        repository: repository,
      );
      expect(
        find.textContaining('no engine to translate with'),
        findsOneWidget,
      );
    });

    testWidgets('says nothing more with an on-device engine', (tester) async {
      tester.setScreenSize(const Size(400, 1400));
      final repository = MockTranslationRepository();
      when(() => repository.hasOfflineEngine).thenReturn(true);
      await tester.pumpOnboarding(
        const PrivacyStep(),
        onboarding: createOnboardingCubit(),
        repository: repository,
      );
      expect(find.textContaining('no engine to translate with'), findsNothing);
    });
  });
}
